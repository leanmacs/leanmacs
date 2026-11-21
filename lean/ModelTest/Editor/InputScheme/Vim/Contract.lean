import Editor.Event
import Editor.InputScheme.Contract
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Scene
import Editor.Test.Keys
import ModelTest.Check
import ModelTest.Support.Vim

/-!
# Model tests: the scheme contract, run on the Vim scheme

`vimContractChecks`: the scheme contract (`Editor/InputScheme/Contract.lean`)
holds of the Vim scheme (`Editor/InputScheme/Vim.lean`), over the registry
written for the Vim checks and over its default states
(`Editor/InputScheme/Vim/Default.lean`). A contract run over a shipped value
is the shipped value's test, so these are evil's. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test
open Editor.SchemeContract (failsOnly)

/-- The key the Vim checks give the scheme contract as unbound: a named
key. A key that prints goes on with one strict prefix whatever is bound,
the register prefix, by naming the register. -/
def vimUnbound : Key :=
  namedKey ⟨"F12"⟩

/-- The subject the scheme contract is run on for the Vim scheme over
`states`: the scheme with the checks' role table and leader and no active
keymaps, for view 0, and `z`, which no keymap of the checks' states binds,
as the key that prints. -/
def vimSubjectOver (states : Vim.States) : SchemeContract.Subject :=
  { scheme := Vim.scheme states vimModeKeys
    maps := vimNoMaps
    view := ⟨0⟩
    sequences := vimSequences.map keys
    unbound := vimUnbound
    printable := charKey "z" }

/-- The subject the scheme contract is run on for the Vim scheme: the
scheme over `vimStates`. -/
def vimSubject : SchemeContract.Subject :=
  vimSubjectOver vimStates

/-- The subject the scheme contract is run on for the Vim scheme that
ships: the default scheme, with no active keymaps, for view 0. -/
def vimDefaultSubject : SchemeContract.Subject :=
  { scheme := Vim.Default.scheme
    maps := vimNoMaps
    view := ⟨0⟩
    sequences := ["d 2 w", "2 d 3 w", "d d", "g g", "\" + y w", "i"].map keys
    unbound := vimUnbound
    printable := charKey "z" }

/-- The checks that the Vim scheme keeps the scheme contract
(`Editor/InputScheme/Contract.lean`). -/
def vimContractChecks : List Check :=
  [{  name := "the scheme contract holds of the Vim scheme over the registry written for the checks"
      run := pure (SchemeContract.failures vimSubject == []) },
    { name := "the scheme contract holds of the Vim scheme that ships, over its default states"
      run := pure (SchemeContract.failures vimDefaultSubject == []) },
    { name :=
        "a key that prints is not unbound after the register prefix, where it names the register: given one as its unbound key, the scheme contract reports that it does not reset"
      run :=
        pure
          (failsOnly { vimSubject with unbound := charKey "z" } [SchemeContract.unboundResets]) },
    { name :=
        "the Vim scheme over a registry that names no state for the minibuffer leaves the minibuffer's view where a key that prints is no text: the scheme contract reports it, for that property alone"
      run :=
        pure
          (failsOnly (vimSubjectOver { vimStates with minibuffer := none })
            [SchemeContract.minibufferTakesText]) }]

end ModelTest
