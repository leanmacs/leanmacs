import Editor.Text

/-!
# The contract of the text port

What every implementation of the text port (`Editor/Text.lean`) does, as one
list of properties. A property is a command that returns whether it held, so
the same list runs against the pure model (`model-test`, under `lake test`)
and against the real binding (`contract-test`, linked with the Rust library).
That is what keeps the model from drifting from the library.

This module imports only the port. The list is plain data, programs that have
not run, so it is a constant: nothing in it calls the library when the module
is initialised.

Offsets are byte offsets. "é" and "ö" are two bytes each, so in `"héllo"` the
offsets 0, 1, 3, 4, 5 and 6 are character boundaries and 2 is inside "é".
-/

namespace Editor.TextContract

/-- One property of the text port: a command that observes it. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the property, from an empty store; `true` when it holds. A
  command that fails has not held. -/
  holds : EditorM Bool

/-- Runs `command` and returns whether it was refused with `error`. -/
def refusedWith (error : TextError) (command : EditorM Unit) : EditorM Bool :=
  try
    command
    return false
  catch refusal =>
    return refusal == error

/-- The properties every implementation of the text port has. -/
def properties : List Property :=
  [{
      name :=
        "a new text reads back what it was made with, multi-byte characters and an embedded NUL included",
      holds := do
        let text ← createText "héllo\x00wörld"
        let empty ← createText ""
        return (← text.read) == "héllo\x00wörld" && (← empty.read) == "" },
    { name := "an insert at a character boundary lands at that byte offset"
      holds := do
        let text ← createText "héllo"
        text.insert 3 "XY"
        let middle ← text.read
        text.insert 0 "<"
        let start ← text.read
        text.insert 9 ">"
        return middle == "héXYllo" && start == "<héXYllo" && (← text.read) == "<héXYllo>" },
    { name := "an insert inside a character is refused and changes nothing"
      holds := do
        let text ← createText "héllo"
        let refused ← refusedWith .badRange (text.insert 2 "x")
        return refused && (← text.read) == "héllo" },
    { name := "an insert past the end is refused, and so is one at an offset no machine word holds"
      holds := do
        let text ← createText "héllo"
        let pastEnd ← refusedWith .badRange (text.insert 7 "x")
        let huge ← refusedWith .badRange (text.insert (2 ^ 64 + 1) "x")
        return pastEnd && huge && (← text.read) == "héllo" },
    { name := "a delete removes exactly its byte range"
      holds := do
        let text ← createText "héllo wörld"
        text.delete 1 3
        let middle ← text.read
        text.delete 5 11
        return middle == "hllo wörld" && (← text.read) == "hllo " },
    { name :=
        "a delete whose range is backwards, splits a character or runs past the end is refused and changes nothing"
      holds := do
        let text ← createText "héllo"
        let backwards ← refusedWith .badRange (text.delete 3 1)
        let split ← refusedWith .badRange (text.delete 0 2)
        let pastEnd ← refusedWith .badRange (text.delete 3 7)
        return backwards && split && pastEnd && (← text.read) == "héllo" },
    { name := "two texts are independent and have different ids"
      holds := do
        let first ← createText "a"
        let second ← createText "b"
        first.insert 1 "1"
        second.delete 0 1
        return first != second && (← first.read) == "a1" && (← second.read) == "" },
    { name := "an id that no create returned is refused"
      holds := do
        let never : TextId := ⟨99⟩
        let before ← refusedWith .noSuchText (discard never.read)
        let made ← createText "a"
        let read ← refusedWith .noSuchText (discard never.read)
        let insert ← refusedWith .noSuchText (never.insert 0 "x")
        let delete ← refusedWith .noSuchText (never.delete 0 0)
        return before && read && insert && delete && (← made.read) == "a" }]

/-- Runs each of `properties` with `run`, which must start every command from
an empty store, and returns the names of those that did not hold. A property
whose command failed is named with the error it failed with. -/
def failures (run : EditorM Bool → IO (Except TextError Bool)) (properties : List Property) :
    IO (List String) :=
  properties.filterMapM fun property => do
    match ← run property.holds with
    | .ok true =>
      return none
    | .ok false =>
      return some property.name
    | .error error =>
      return some s!"{property.name} (the command failed with {repr error})"

end Editor.TextContract
