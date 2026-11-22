import BuffersApi
import Editor.Config.Packages
import Editor.Test.Hosted

/-!
# The contract check of `buffers-api`

What every implementation of the interface library `buffers-api`
(`BuffersApi.lean`) runs over its package, in two parts.

- **What it registers**, collected with the pure collector
  (`Package.registered`): a command under each name the interface declares,
  and a `BuffersApi.Buffers` value under the implementation's name,
  `buffers`.
- **What it does**, on the loop's driver over the models with the package
  installed as a host installs it beside a probe of the interface's own
  (`Editor.Test.hostedDriver`, `probe`): closing a buffer, by `close-buffer`
  and by the `Buffers` value's `close`, runs every `BuffersApi.Closing` value
  once, while the buffer is still there, and the buffer is gone after.

It is a list of sentences, each with whether it holds, as the fixture
interface package `greeting-api`'s (`tests/packages/greeting-api`).
-/

namespace BuffersApiTest

open Editor
open Editor.Test

/-- The probe's two hook values at `Closing`, each making a text saying the
buffer it was handed and whether the buffer was still there; its command
`probe-victim`, which makes a buffer `victim` and shows it in the window it
is called with; and its command `probe-close`, which closes the buffer
`victim` through the `Buffers` value's `close`. -/
def probe : Package :=
  { name := "buffers-api-probe"
    setup := do
      for name in ["probe-a", "probe-b"] do
        Extension.add
            ({  name
                closing := fun id => do
                  let present := ((← editorState).buffer? id).isSome
                  discard <| createText s!"closing {name} {id.index} {present}" } :
              BuffersApi.Closing)
      commandWith "probe-victim" fun call => do
          if let .ok made← createBuffer "victim" then
            discard <| call.target.window.id.show made
      command "probe-close" do
          let some buffers ← BuffersApi.buffers? | message "no buffers implementation"
          let some victim := (← editorState).findBuffer "victim" | message "no victim"
          buffers.close victim }

/-- The texts `driver`'s model holds that start with `lead`. -/
def textsStarting (driver : TestDriver) (lead : String) : Array String :=
  driver.model.texts.contents.filter (·.startsWith lead)

/-- The checks of the contract over `package`, each with what must hold as a
sentence. -/
def contractChecks (package : Package) : List (String × Bool) :=
  let registered := Package.registered package
  let commands := registered.commands.map (·.name)
  let values : Array BuffersApi.Buffers :=
    registered.extensions.filterMap fun (key, value) =>
      if key == TypeName.typeName BuffersApi.Buffers then value.get? BuffersApi.Buffers else none
  let victim :=
    (hostedDriver #[package, probe]).map fun driver =>
      hostedRan driver { command := "probe-victim" }
  let closedBy (invocation : Invocation) : Bool :=
    match victim with
    | some driver =>
      match driver.loop.state.findBuffer "victim" with
      | some id =>
        let closed := hostedRan driver invocation
        textsStarting closed "closing " ==
            #[s!"closing probe-a {id.index} true", s!"closing probe-b {id.index} true"] &&
          (closed.loop.state.findBuffer "victim").isNone
      | none => false
    | none => false
  (BuffersApi.names.toList.map fun name =>
      (s!"`{package.name}` registers a command under `{name}`, a name `buffers-api` declares",
        commands.contains name)) ++
    [(s!"`{package.name}` registers a `BuffersApi.Buffers` value named `{BuffersApi.implementationName}`",
        values.any (·.name == BuffersApi.implementationName)),
      (s!"closing a buffer through `{BuffersApi.closeName}` of `{package.name}` runs every `BuffersApi.Closing` value once while it is there, and it is gone after",
        closedBy { command := BuffersApi.closeName }),
      (s!"closing a buffer through the `close` of `{package.name}`'s `BuffersApi.Buffers` value runs every `BuffersApi.Closing` value once while it is there, and it is gone after",
        closedBy { command := "probe-close" })]

end BuffersApiTest
