import ConfigTest.Check
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import ConfigTest.Support.Lines
import ConfigTest.Support.Syntax

/-!
# Config tests: `Editor/Setup.lean`

The tests of `Editor/Setup.lean`: `leaderChecks`, the leader config sets
(`leaderKey`) and the bindings it writes under `<leader>`, through a host of
the Vim scheme that ships. The root module `ConfigTest` runs them; its module
doc says what each shows.
-/

namespace ConfigTest

open Editor

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

/-- The checks of the leader through a host of the Vim scheme that ships
(`withRealVimHost`), with the real elaborator and the recorder: a config's
binding written with `<leader>` is reached under the scheme's leader, `SPC`,
under the leader config sets once it is reloaded, and is kept out of
insert state, where `SPC` types a space (`Editor/Setup.lean`, the leader;
`docs/design/keymaps-and-modes.md`, "Extending from config"). How the
placeholders expand and where a binding holds is pinned by `ModelTest`'s
checks of the notation, the registry and the Vim scheme. -/
def leaderChecks (context : Context) : List Check :=
  [{  name :=
        "under the Vim scheme with no leader set by config, a config binding of <leader> f f runs its command on SPC f f in normal state"
      run :=
        withRealVimHost context [("init.lean", leaderText)] fun session => do
          session.ask [.reload]
          session.typed "SPC f f"
          return (← session.echo) == "leader find".quote },
    { name :=
        "a config that sets the leader to \\ reaches its <leader> f f binding on \\ f f after a reload, and SPC f f no longer runs it"
      run :=
        withRealVimHost context [("init.lean", leaderText)] fun session => do
          session.ask [.reload]
          session.write "init.lean" (leaderText (some "\\"))
          session.ask [.reload]
          session.typed "\\ f f"
          let moved ← session.echo
          session.ask [.run "other"]
          session.typed "SPC f f"
          let spaced ← session.echo
          return moved == "leader find".quote && spaced != "leader find".quote },
    { name :=
        "SPC typed in insert state inserts a space in a config that binds keys under <leader>, and SPC f f after <Escape> still runs the binding"
      run :=
        withRealVimHost context [("init.lean", leaderText)] fun session => do
          session.ask [.reload]
          session.typed "i a SPC b <Escape>"
          let line := lastViewLine (← session.sceneLines)
          let before ← session.echo
          session.typed "SPC f f"
          let after ← session.echo
          return (line.splitOn s!"{"a b".quote}, scroll").length == 2 &&
              before != "leader find".quote &&
              after == "leader find".quote }]

end ConfigTest
