import Editor.Event
import Editor.Event.Queue
import Editor.Ffi.Events
import Editor.Ffi.Interrupt
import FfiTest.Check
import FfiTest.Support.Queues

/-!
# FFI tests: `Editor/Ffi/Interrupt.lean`

The tests of `Editor/Ffi/Interrupt.lean`: `interruptChecks`. The root module
`FfiTest` runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The key of the character `text` with control held, and shift too when
`shift`. -/
def controlKey (text : String) (shift : Bool := false) : Editor.Key :=
  { logical := .character text, modifiers := { control := true, shift } }

/-- The named key `Tab` with control held, and shift too when `shift`. -/
def controlTab (shift : Bool := false) : Editor.Key :=
  { logical := .named .tab, modifiers := { control := true, shift } }

/-- Posts `key`, pressed or released, as a window would report it, and pulls
it back from the editor queue: whether the interrupt flag was up once the
key had arrived, before anything pulled it, and whether the event pulled is
marked as an interrupt key. The flag is lowered for a marked event, as the
loop lowers it, so the queue is empty and the flag down afterwards. `none`
when the key was not queued, did not come back or did not decode. -/
def arrives (key : Editor.Key) (pressed : Bool := true) : IO (Option (Bool × Bool)) := do
  unless ← Editor.Event.post (.key key pressed "") do
    return none
  let raised ← Editor.Ffi.interruptRaised
  let some pulled ← pull .editor | return none
  let .ok received := Editor.Event.ofFfi pulled | return none
  if received.interrupt then
    Editor.Ffi.interruptLower
  return some (raised, received.interrupt)

/-- Runs `body` with `key` as the library's interrupt key, and leaves the
library with none. `false` when the library did not take the key, when
`body` does not hold, or when the flag is still up after it. -/
def withInterruptKey (key : Editor.Key) (body : IO Bool) : IO Bool := do
  unless ← Editor.Event.setInterruptKey (some key) do
    return false
  try
    let held ← body
    return held && !(← Editor.Ffi.interruptRaised)
  finally
    discard <| Editor.Event.setInterruptKey none

/-- The checks of the interrupt flag against the real library
(`crates/editor-ffi/src/interrupt.rs`): Lean tells the library its interrupt
key, a press of that key raises the flag as it arrives and its event is
marked, and Lean lowers the flag. Each leaves the queue empty, the flag down
and no interrupt key. -/
def interruptChecks (_ : Unit) : List Check :=
  [{  name :=
        "once Lean has told the library its interrupt key, a press of it raises the flag as it arrives, the event pulled is marked, and lowering brings the flag down"
      run :=
        withInterruptKey (controlKey "g") do
          let before ← Editor.Ffi.interruptRaised
          return !before && (← arrives (controlKey "g")) == some (true, true) },
    { name :=
        "a chord drops shift on a character, so the interrupt key's character with shift held raises the flag too"
      run :=
        withInterruptKey (controlKey "g") do
          return (← arrives (controlKey "g" true)) == some (true, true) },
    { name :=
        "another character with the interrupt key's modifiers, its character with none or with one more, a release of it and another key raise nothing and are not marked"
      run :=
        withInterruptKey (controlKey "g") do
          let others : List (Editor.Key × Bool) :=
            [(controlKey "G", true), ({ logical := .character "g" }, true),
              ({ controlKey "g" with modifiers := { control := true, alt := true } }, true),
              (controlKey "g", false), (controlKey "x", true), (controlTab, true)]
          others.allM fun (key, pressed) => return (← arrives key pressed) == some (false, false) },
    { name :=
        "a chord keeps shift on a named key, so with a named key as the interrupt key the key with shift held is another key"
      run :=
        withInterruptKey controlTab do
          return (← arrives controlTab) == some (true, true) &&
              (← arrives (controlTab true)) == some (false, false) },
    { name :=
        "two presses of the interrupt key need two lowers: the flag is still up after the first"
      run :=
        withInterruptKey (controlKey "g") do
          let posted ←
            [controlKey "g", controlKey "g"].allM fun key => Editor.Event.post (.key key true "")
          let pulled ← [(), ()].mapM fun _ => pull .editor
          let marked :=
            pulled.all fun event =>
              (event.bind fun event => (Editor.Event.ofFfi event).toOption).map (·.interrupt) ==
                some true
          Editor.Ffi.interruptLower
          let between ← Editor.Ffi.interruptRaised
          Editor.Ffi.interruptLower
          return posted && marked && between && !(← Editor.Ffi.interruptRaised) },
    { name :=
        "with no interrupt key told, the key raises nothing and arrives unmarked, and a lower with nothing raised is nothing"
      run := do
        Editor.Ffi.interruptLower
        return (← Editor.Event.setInterruptKey none) &&
            (← arrives (controlKey "g")) == some (false, false) &&
            !(← Editor.Ffi.interruptRaised) },
    { name :=
        "the words of an interrupt key are its logical key, its modifiers as a chord has them, and the modifiers a chord compares: every one but shift for a character, and every one for a named key"
      run :=
        pure
          (Editor.EventWords.interruptWords (controlKey "g" true) == #[1, 1, 103, 2, 14] &&
            Editor.EventWords.interruptWords (controlTab true) == #[2, 3, 84, 97, 98, 3, 15] &&
            Editor.EventWords.interruptWords { logical := .character "é" } ==
              #[1, 1, 233, 0, 14]) },
    { name := "words that are not an interrupt key are refused by the library, and set none"
      run := do
        let refused ← Editor.Ffi.interruptKeySet #[1, 1, 103, 2]
        let unmasked ← Editor.Ffi.interruptKeySet #[1, 1, 103, 3, 14]
        return !refused && !unmasked && (← arrives (controlKey "g")) == some (false, false) }]

end FfiTest
