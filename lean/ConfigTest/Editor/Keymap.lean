import ConfigTest.Check
import ConfigTest.Support.Shipped
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys

/-!
# Config tests: `Editor/Keymap.lean`

The tests of `Editor/Keymap.lean`: `hintChecks`, what the key hints list of
a config's binding descriptions and prefix names (`Keymap.continuations`),
through a host of the test scheme. The root module `ConfigTest` runs them; its
module doc says what each shows. That the Vim scheme lists them after its
leader is evil's (`evilLeaderChecks`, `packages/evil/EvilTest/Linked/Evil.lean`).
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- A config whose `setup` registers `leader-find`, which says `leader find`
in the echo area, binds `<leader> f f` to it described as `Find file`, and,
when `named`, names the prefix `<leader> f` `file`. It sets the key hint
delay to 0, so the hints are in the scene after the prefix with no move of
the clock: what they list is checked apart from when (`keyHintChecks`). -/
def hintText (named : Bool) : String :=
  "def setup : SetupM Unit := do
  command \"leader-find\" (message \"leader find\")
  bindKey \"<leader> f f\" \"leader-find\" (desc := \"Find file\")
  keyHintDelay 0
" ++
    if named then "  prefixName \"<leader> f\" \"file\"\n" else ""

/-- The checks of the key hints through a host of the test scheme
(`withTestHost`), with the real elaborator: a config's description of a
binding and its name of a prefix are in the scene's hints once it is
reloaded, and a reload that drops the name drops it from them. What the
hints list, and in which order, is pinned by `ModelTest`'s checks of the
keymap, the test scheme and the loop. -/
def hintChecks (context : Context) : List Check :=
  [{  name :=
        "criterion 4: after a reload, the scheme's leader lists f as the prefix config named, the leader and then f lists f as the binding config described, and the leader and then f f runs it and lists nothing"
      run :=
        withTestHost context [("init.lean", hintText true)] fun session => do
          session.ask [.reload]
          session.typed schemeLeader
          let afterLeader ← session.hints
          session.typed "<Escape>"
          session.typed s!"{schemeLeader} f"
          let afterPrefix ← session.hints
          session.typed "f"
          let afterBinding ← session.hints
          return afterLeader.contains "hint f: prefix \"file\" 1" &&
              afterPrefix == #["hint f: binding \"Find file\""] &&
              afterBinding.isEmpty &&
              (← session.echo) == "leader find".quote },
    { name :=
        "criterion 5: a reload that drops a config's prefix name drops it from the hints, and the prefix is listed unnamed"
      run :=
        withTestHost context [("init.lean", hintText true)] fun session => do
          session.ask [.reload]
          session.typed schemeLeader
          let named ← session.hints
          session.typed "<Escape>"
          session.write "init.lean" (hintText false)
          session.ask [.reload]
          session.typed schemeLeader
          let unnamed ← session.hints
          return named.contains "hint f: prefix \"file\" 1" &&
              unnamed.contains "hint f: prefix - 1" &&
              !unnamed.any (·.startsWith "hint f: prefix \"file\"") }]

end ConfigTest
