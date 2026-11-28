import Editor.Test.Driver

/-!
# Model tests: support: Inside

A command's program stepped request by request on a driver, the commands it
runs inside itself recorded and not run (`ranInside`): what a check of a
command that falls back to the command a buffer's mode fills a role with
reads, so that a command which would run itself again for ever fails the
check on its first such request, where pressing its key would never come
back. The link checks (`ModelTest/Editor/Links.lean`) and the fold checks
(`ModelTest/Editor/Folds.lean`) use it. It holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- `program` run in `driver`'s editor, its requests answered as the loop
answers them (the registry's questions from what the loop was told is
registered, the state's from its state, the rest from its models), except
that a command it runs inside itself is not run: its name is added to
`ran` and it is answered as run. The names it ran and the driver after its
last request; `none` once it has made `fuel` requests. -/
def ranInside {α : Type} :
    Nat → TestDriver → Array String → Program editorPort α → Option (Array String × TestDriver)
  | 0, _, _, _ => none
  | _ + 1, driver, ran, .done _ => some (ran, driver)
  | fuel + 1, driver, ran, .step (.control (.runCommand name _)) next =>
    ranInside fuel driver (ran.push name) (next true)
  | fuel + 1, driver, ran, .step (.registry request) next =>
    ranInside fuel driver ran (next (driver.keys.registered.answer driver.loop.state request))
  | fuel + 1, driver, ran, .step (.state request) next =>
    let (reply, state) := driver.loop.state.handle request
    ranInside fuel { driver with loop := { driver.loop with state } } ran (next reply)
  | fuel + 1, driver, ran, .step request next =>
    let (reply, model) := driver.model.handle request
    ranInside fuel { driver with model } ran (next reply)

end ModelTest
