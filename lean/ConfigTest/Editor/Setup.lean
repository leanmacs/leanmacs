import ConfigTest.Check
import ConfigTest.Support.Shipped
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Setup

/-!
# Config tests: `Editor/Setup.lean`

The tests of `Editor/Setup.lean`: `leaderChecks`, the leader config sets
(`leaderKey`) and the bindings it writes under `<leader>`, through a host of
the test scheme. The root module `ConfigTest` runs them; its module doc says
what each shows; and `processEnvironmentChecks`, a config that still calls
the retired `processEnvironment` refused at reload with a diagnostic that
names what replaces it. What the Vim scheme's leader is, and that it is kept out of
the state where typing is text, are evil's (`evilLeaderChecks`,
`packages/evil/EvilTest/Linked/Evil.lean`).
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- A config whose `setup` registers `leader-find`, which says `leader find`
in the echo area, and `other`, which says `other`, binds `<leader> f f` to
`leader-find`, and, given `leader`, sets the leader to the key string
`leader`. -/
def leaderText (leader : Option String := none) : String :=
  "def setup : SetupM Unit := do
  command \"leader-find\" (message \"leader find\")
  command \"other\" (message \"other\")
  bindKey \"<leader> f f\" \"leader-find\"
" ++
    (leader.map fun keys => s!"  leaderKey {keys.quote}\n").getD ""

/-- The checks of the leader through a host of the test scheme
(`withTestHost`), with the real elaborator and the recorder: a config's
binding written with `<leader>` is reached under the scheme's leader, and
under the leader config sets once it is reloaded, when the scheme's no
longer reaches it (`Editor/Setup.lean`, the leader;
`docs/design/keymaps-and-modes.md`, "Extending from config"). How the
placeholders expand and where a binding holds is pinned by `ModelTest`'s
checks of the notation and the registry. -/
def leaderChecks (context : Context) : List Check :=
  [{  name :=
        "with no leader set by config, a config binding of <leader> f f runs its command on the scheme's leader and then f f"
      run :=
        withTestHost context [("init.lean", leaderText)] fun session => do
          session.ask [.reload]
          session.typed s!"{schemeLeader} f f"
          return (← session.echo) == "leader find".quote },
    { name :=
        "a config that sets the leader to \\ reaches its <leader> f f binding on \\ f f after a reload, and the scheme's leader and then f f no longer runs it"
      run :=
        withTestHost context [("init.lean", leaderText)] fun session => do
          session.ask [.reload]
          session.write "init.lean" (leaderText (some "\\"))
          session.ask [.reload]
          session.typed "\\ f f"
          let moved ← session.echo
          session.ask [.run "other"]
          session.typed s!"{schemeLeader} f f"
          let former ← session.echo
          return moved == "leader find".quote && former != "leader find".quote }]

/-- A config whose `setup` calls the retired `processEnvironment` with
`setting`, written as Lean. -/
def processEnvironmentText (setting : String) : String :=
  s!"def setup : SetupM Unit := do\n  processEnvironment {setting}\n"

/-- The checks of the retired `processEnvironment` through the headless host,
with the real elaborator: a config that still calls it is refused at reload,
its diagnostic the refusal, which names what replaces it, the mise package's
setting `Mise.executable` and the package `mise`. -/
def processEnvironmentChecks (context : Context) : List Check :=
  let refusedWith (text : String) (setting : Process.Setting) : IO Bool :=
    withHost context [("init.lean", processEnvironmentText text)] fun session => do
      session.ask [.reload]
      let lines ← session.output.get
      return lines.contains "reload 1: rejected" &&
          lines.contains s!"diagnostic: setup:0:0: error: {processEnvironmentGone setting}"
  [{  name :=
        "a config that calls processEnvironment with a path to mise is refused at reload, and its diagnostic names Mise.executable with that path"
      run := do
        let path := "/opt/homebrew/bin/mise"
        let said := processEnvironmentGone (.mise (some path))
        return (← refusedWith s!"(.mise (some {path.quote}))" (.mise (some path))) &&
            (said.splitOn s!"Mise.executable {path.quote}").length > 1 },
    { name :=
        "a config that calls processEnvironment .inherited is refused at reload, and its diagnostic says to leave the package mise out"
      run := do
        let said := processEnvironmentGone .inherited
        return (← refusedWith ".inherited" .inherited) &&
            (said.splitOn "leave the package `mise` out").length > 1 }]

end ConfigTest
