import ConfigTest.Check
import ConfigTest.Support.Shipped
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys

/-!
# Config tests: `Editor/Setup.lean`

The tests of `Editor/Setup.lean`: `leaderChecks`, the leader config sets
(`leaderKey`) and the bindings it writes under `<leader>`, through a host of
the test scheme. The root module `ConfigTest` runs them; its module doc says
what each shows. What the Vim scheme's leader is, and that it is kept out of
the state where typing is text, are evil's (`evilLeaderChecks`,
`ConfigTest/Editor/Evil.lean`).
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

end ConfigTest
