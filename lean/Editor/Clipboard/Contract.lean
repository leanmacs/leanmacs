import Editor.Clipboard

/-!
# The contract of the clipboard interface

What every implementation of the clipboard interface
(`Editor/Clipboard.lean`) answers, as one list of properties. The model
(`Editor/Clipboard/Model.lean`) is held to it by `model-test`, and every
other implementation runs the same list, so none can drift from the model
the editor's commands are tested on. This module imports only the port, so
the contract never depends on an implementation.

## How a runner runs a property

A property's `holds` is a program over the clipboard port. A runner runs it
against an implementation that can be reached.

- **A property assumes nothing of what the clipboard held before it.** A
  system's clipboard holds whatever the user last copied, so every property
  writes before it reads what it wrote, and the one that does not write
  compares two reads with each other.
- **A request that is refused fails its property.** The contract is of a
  clipboard that is there. What a command does when it is not is the
  command's, pinned on the model, which a test can take away
  (`ClipboardModel.available`).
- **A property writes the clipboard.** Run against a system's clipboard it
  replaces what the user copied: whoever binds one decides when the
  contract runs and whether what was held is put back.

## What is left loose, so that a system's clipboard can pass

- **After a write of the empty text a read answers the empty text or no
  text.** Some systems cannot hold an empty text and clear the clipboard
  instead.
- **No sample holds a carriage return.** Some systems translate line
  endings on the way in or out.

Both are for whoever binds a system's clipboard to tighten, with its
adapter in hand.
-/

namespace Editor.ClipboardContract

/-- One property of the clipboard interface. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the property; `true` when it holds. -/
  holds : ClipboardM Bool

/-- Whether a write of `text` is accepted. -/
def writes (text : String) : ClipboardM Bool :=
  return (← Clipboard.write text) matches .ok ()

/-- Whether a read answers the text `text`. -/
def reads (text : String) : ClipboardM Bool :=
  return match ← Clipboard.read with
    | .ok (some held) => held == text
    | _ => false

/-- The texts a write of which must be read back as written, each with what
it is: one word; two lines that each end in a line feed; a text with a
two-byte character, a character outside the basic plane and a three-byte
character; a text with blanks at both ends; and 4,096 bytes. -/
def samples : List (String × String) :=
  [("one word", "word"), ("two lines that each end in a line feed", "first line\nsecond line\n"),
    ("a text with é, an emoji and a CJK character", "é 🙂 漢"),
    ("a text with leading and trailing spaces", "  padded  "),
    ("a text of 4,096 bytes", "".pushn 'x' 4096)]

/-- The properties of the clipboard interface. -/
def properties : List Property :=
  (samples.map fun (what, text) =>
      { name := s!"after a write of {what}, a read answers that text"
        holds := do
          let written ← writes text
          return written && (← reads text) }) ++
    [{  name := "a second write replaces the first: a read answers the text written last"
        holds := do
          let first ← writes "first"
          let second ← writes "second"
          return first && second && (← reads "second") },
      { name := "two reads with no write between them answer the same"
        holds := do
          match ← Clipboard.read, ← Clipboard.read with
          | .ok first, .ok second =>
            return first == second
          | _, _ =>
            return false },
      { name :=
          "after a write of the empty text a read answers the empty text or no text, and a write after it is read back"
        holds := do
          let seeded ← writes "before"
          let emptied ← writes ""
          let cleared :=
            match ← Clipboard.read with
            | .ok (some held) => held.isEmpty
            | .ok none => true
            | .error _ => false
          let again ← writes "after"
          return seeded && emptied && cleared && again && (← reads "after") }]

/-- The names of `properties` that do not hold. `run` runs one property
against an implementation, as the module docs say. -/
def failures (run : Property → IO Bool) (properties : List Property) : IO (List String) :=
  properties.filterMapM fun property => do
    return if ← run property then none else some property.name

end Editor.ClipboardContract
