import Editor.Api

/-!
# Evil's registers

What a yank and a deletion keep, and what a put inserts
(`docs/design/keymaps-and-modes.md`, "Registers"). A register is a text and
whether it is line-wise (`Register`), kept by name in the editor state
(`Editor/State.lean`, "Registers"), so a command that sets one and then
does not run to its end leaves the register it had.

- **The unnamed register** is kept under the name `"` (`unnamed`), which is
  the name Vim gives it.
- **Every yank and every deletion sets the unnamed register** (`store`),
  whatever register the call named, as Vim's does.
- **The names evil knows** (`named?`): the empty name, which is a call that
  named no register, and `"`, which are the unnamed register; and `+`, the
  system clipboard, reached through the clipboard port
  (`Editor/Clipboard.lean`). Any other name gives the command up
  (`noRegister`): named registers are not built. The table in the editor
  state is by name so that one is another name and no new request.

## The clipboard is written last

The clipboard is outside the editor: what is written there stays when a
command is rolled back. A command is stopped only before a request it
makes of a port, never after its last. So a command that names the
clipboard edits, places its cursor, and then stores (`store`), whose write
of the clipboard is the last request the command makes: a command that
wrote the clipboard ran to its end. A write that is refused is said in the
echo area, and the text is in the unnamed register.

A yank that took no cell empties the unnamed register and writes nothing
to the clipboard.

Pinned by `ModelTest.evilOperatorChecks` and `ModelTest.evilRegisterChecks`,
by key.
-/

namespace Editor.Evil

/-- The name the unnamed register is kept under in the editor state. -/
def unnamed : String :=
  "\""

/-- The name of the register that is the system clipboard. -/
def clipboard : String :=
  "+"

/-- What a command gives up with when its call names the register `name`,
which evil has none of. -/
def noRegister (name : String) : String :=
  s!"no register {name}"

/-- What a command says in the echo area when the clipboard it was to write
could not be reached, and what one gives up with when the clipboard it was
to read could not. -/
def clipboardUnavailable : String :=
  "the clipboard is unavailable"

/-- A register evil knows, as a call names it. -/
inductive Named where
  /-- The unnamed register. -/
  | unnamed
  /-- The system clipboard. -/
  | clipboard
  deriving DecidableEq, Repr

/-- The register the name `name` stands for: the unnamed one for the empty
name, which is a call that named none, and for `"`; the clipboard for `+`;
and none for any other name. -/
def named? (name : String) : Option Named :=
  if name.isEmpty || name == unnamed then some .unnamed
  else if name == clipboard then some .clipboard else none

/-- The register `name` stands for, for a command that is about to act:
the command gives up when evil has no register of that name. A command
that takes a register's name asks this before it changes anything it is
not to change for a register there is none of. -/
def registerNamed (name : String) : EditorM Named := do
  let some named := named? name | giveUp (noRegister name)
  return named

/-- Keeps `register` as what a yank or a deletion took, for a call that
named the register `name`: the unnamed register holds it, and when the name
is the clipboard's and the text is not empty the clipboard is written too.
A write that is refused is said in the echo area (`clipboardUnavailable`),
and the text is in the unnamed register all the same. The write is this
operation's last request, so a command calls it last ("The clipboard is
written last", in the module docs). A name evil has no register of gives
the command up. -/
def store (name : String) (register : Register) : EditorM Unit := do
  let named ← registerNamed name
  setRegister unnamed register
  if named == .clipboard && !register.text.isEmpty then
    match ← Clipboard.write register.text with
    | .ok () =>
      pure ()
    | .error .unavailable =>
      message clipboardUnavailable

end Editor.Evil
