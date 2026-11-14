import Editor.Evil

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

## Putting

`put` is the command `p` and `P` run (`putAfter`, `putBefore`). It inserts
the register its call names (`fetch`): the unnamed one, or the text the
clipboard holds, read through the clipboard port, which is line-wise when
it ends in a line feed.

| The register | `P` | `p` | The cursor |
|---|---|---|---|
| Character-wise | Inserts at the cursor | Inserts after the cursor's cell, and at the cursor on an empty line | The last cell put when the text holds no line break, and the first cell put when it holds one |
| Line-wise | Inserts the lines at the start of the cursor's line | Inserts them at the start of the next line. Below a last line with no line break it inserts the buffer's line ending and then the lines without their last line break, so the text ends the way it ended | The first non-blank of the first line put |

- **The text is put `count` times**, in one edit, which carries the
  selection from before the command and the cursor it leaves
  (`Target.replaceCarrying`), so a put is one step of the history.
- **With nothing to put the command gives up** and changes nothing: a
  register nothing was set in or that holds the empty text, a clipboard
  that holds no text (`nothingToPut`), and a clipboard that cannot be
  reached (`clipboardUnavailable`).
- **Not built: `p` and `P` in a visual state.** The visual tables do not
  bind them.

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

/-- What a put gives up with when the register it names holds nothing to
put: nothing was set in it, it holds the empty text, or the clipboard holds
no text. -/
def nothingToPut : String :=
  "nothing to put"

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

/-- The register a put is to insert, for a call that named the register
`name`: the unnamed register from the editor state, or the text the
clipboard holds, which is line-wise when it ends in a line feed, the
clipboard holding a text and no flag. The command gives up when there is
nothing to put (`nothingToPut`), when the clipboard cannot be reached
(`clipboardUnavailable`), and for a name evil has no register of. -/
def fetch (name : String) : EditorM Register := do
  let register ←
    match ← registerNamed name with
    | .unnamed =>
      pure ((← editorState).register? unnamed)
    | .clipboard =>
      match ← Clipboard.read with
      | .ok held =>
        pure (held.map fun text => { text, linewise := text.endsWith "\n" })
      | .error .unavailable =>
        giveUp clipboardUnavailable
  match register with
  | some register =>
    if register.text.isEmpty then
      giveUp nothingToPut
    return register
  | none =>
    giveUp nothingToPut

/-- `text` without the line break it ends in, if it ends in one. -/
def withoutLastBreak (text : String) : String :=
  if text.endsWith "\r\n" then (text.dropEnd 2).toString
  else if text.endsWith "\n" then (text.dropEnd 1).toString else text

/-- The put command, after the cursor when `after` and before it otherwise,
as it is called ("Putting", in the module docs): with the count and the
register a command's key compiles to, each of which may be left out. The
register's text is inserted `count` times, 1 with no count, in one edit
that carries the selection from before the command and the cursor it
leaves, and the window keeps no wanted column. With nothing to put the
command gives up (`fetch`). -/
def put (after : Bool) (call : Call) : EditorM Unit := do
  let (count, name) :=
    match call.arguments with
    | .nat count :: .str name :: _ => (count, name)
    | .nat count :: _ => (count, "")
    | _ => (0, "")
  let register ← fetch name
  let text := call.target.buffer.text
  let before ← call.target.selection
  let some range := before.ranges[before.primary]? | throw .badSelection
  let head := range.head
  let put := String.join (List.replicate (max count 1) register.text)
  discard <| call.target.window.id.setWanted none
  if register.linewise then
    -- The cursor goes to the first non-blank of the first line put.
    let indent := (put.takeWhile fun char => char == ' ' || char == '\t').utf8ByteSize
    let below ← text.motion .lineEnd head
    if !after then
      let start ← text.motion .lineStart head
      call.target.replaceCarrying ⟨start, start⟩ put before (cursorAt call (start + indent))
      settle call (start + indent)
    else if below < (← text.byteLength) then
      -- Past the line's line break, where the next line starts.
      let start ← text.motion .nextCell below
      call.target.replaceCarrying ⟨start, start⟩ put before (cursorAt call (start + indent))
      settle call (start + indent)
    else
      -- Below a last line with no line break: the line break goes before
      -- the lines, and their last one is left out.
      let ending := call.target.buffer.lineEnding.text
      let start := below + ending.utf8ByteSize + indent
      call.target.replaceCarrying ⟨below, below⟩ (ending ++ withoutLastBreak put) before
          (cursorAt call start)
      settle call start
  else
    -- After the cursor's cell, which on an empty line is at the cursor.
    let start ←
      if after && head < (← text.motion .lineEnd head) then
        text.motion .nextCell head
      else
        pure head
    let stop := start + put.utf8ByteSize
    if put.any (· == '\n') then
      call.target.replaceCarrying ⟨start, start⟩ put before (cursorAt call start)
      settle call start
    else
      -- On the last cell put. The edit carries the start of the text's last
      -- character, which is that cell's start unless the cell is of more
      -- than one character.
      let last := stop - (put.back.utf8Size)
      call.target.replaceCarrying ⟨start, start⟩ put before (cursorAt call last)
      settle call (← text.motion .previousCell stop)

/-- The command that puts a register after the cursor, Vim's `p`. -/
def putAfter (call : Call) : EditorM Unit :=
  put true call

/-- The command that puts a register before the cursor, Vim's `P`. -/
def putBefore (call : Call) : EditorM Unit :=
  put false call

end Editor.Evil
