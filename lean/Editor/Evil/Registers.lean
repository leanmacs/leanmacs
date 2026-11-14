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
  whatever register the call named.

Pinned by `ModelTest.evilOperatorChecks`, by key.
-/

namespace Editor.Evil

/-- The name the unnamed register is kept under in the editor state. -/
def unnamed : String :=
  "\""

/-- Keeps `register` as what a yank or a deletion took, for a call that
named the register `name`: the unnamed register holds it. -/
def store (_name : String) (register : Register) : EditorM Unit :=
  setRegister unnamed register

end Editor.Evil
