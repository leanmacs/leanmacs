import BuffersApi
import BuffersApiTest.Contract
import BuffersApiTest.Fake
import Editor.Extension
import ModelTest.Check

/-!
# Model tests: `BuffersApi.lean`

`buffersApiChecks`: the interface library `buffers-api`'s names, its fake
held to its contract, and the contract biting on implementations that
leave something out or close without the hook. The root module `ModelTest`
runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- Whether every check of `buffers-api`'s contract over `package` holds. -/
def buffersKeeps (package : Package) : Bool :=
  (BuffersApiTest.contractChecks package).all (·.2)

/-- The checks of `buffers-api` that do not hold over `package`. -/
def buffersFailing (package : Package) : List String :=
  ((BuffersApiTest.contractChecks package).filter (!·.2)).map (·.1)

/-- A package of the buffer commands' name that registers the fake's commands
and a `Buffers` value whose `close` removes the buffer, every window that
shows it showing the buffer 0 first, and runs no hook. -/
def hooklessBuffers : Package :=
  let close (id : BufferId) : EditorM Unit := do
    let state ← editorState
    for view in state.frame.everyWindow do
      if (state.window? view).any (·.buffer == id) then
        discard <| view.show ⟨0⟩
    discard <| id.remove
  { name := BuffersApi.implementationName
    setup := do
      commandWith BuffersApi.switchName fun _ => pure ()
      commandWith BuffersApi.listName fun _ => pure ()
      commandWith BuffersApi.closeName fun call => close call.target.window.buffer
      Extension.add ({ name := BuffersApi.implementationName, close } : BuffersApi.Buffers) }

/-- The checks of `buffers-api` (`BuffersApi.lean`). -/
def buffersApiChecks : List Check :=
  [{  name := "the names buffers-api declares: switch-buffer, list-buffers and close-buffer"
      run :=
        pure
          (BuffersApi.names == #["switch-buffer", "list-buffers", "close-buffer"] &&
            BuffersApi.implementationName == "buffers") },
    { name := "the fake keeps the contract: every check of it holds"
      run := pure (buffersKeeps BuffersApiTest.fake) },
    { name :=
        "a package that registers every command but close-buffer fails the contract: its name's check, and the close through it"
      run :=
        pure <|
          let lacking : Package :=
            { name := BuffersApi.implementationName
              setup := BuffersApiTest.fakeSetup (dropped := [BuffersApi.closeName]) }
          (buffersFailing lacking).length == 2 &&
            (buffersFailing lacking).all fun sentence =>
              (sentence.splitOn s!"`{BuffersApi.closeName}`").length > 1 },
    { name :=
        "an implementation whose close runs no hook fails the contract: both closes' checks are false, and those of what it registers hold"
      run := pure ((buffersFailing hooklessBuffers).length == 2) }]

end ModelTest
