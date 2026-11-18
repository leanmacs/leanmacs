import ConfigTest.Check
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import ConfigTest.Support.Syntax

/-!
# Config tests: `Editor/Keymap.lean`

The tests of `Editor/Keymap.lean`: `hintChecks`, what the key hints list of
a config's binding descriptions and prefix names (`Keymap.continuations`),
through a host of the Vim scheme that ships. The root module `ConfigTest` runs
them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- A chunk whose `setup` registers `leader-find`, which says `leader find`
in the echo area, binds `<leader> f f` to it described as `Find file`, and,
when `named`, names the prefix `<leader> f` `file`. It sets the key hint
delay to 0, so the hints are in the scene after the prefix with no move of
the clock: what they list is checked apart from when (`keyHintChecks`). -/
def hintChunk (named : Bool) : String :=
  "def setup : SetupM Unit := do
  command \"leader-find\" (message \"leader find\")
  bindKey \"<leader> f f\" \"leader-find\" (desc := \"Find file\")
  keyHintDelay 0
" ++
    if named then "  prefixName \"<leader> f\" \"file\"\n" else ""

/-- Asks the host for the scene, and returns its key hint lines: the lines
that start with `hint `. -/
def Session.hints (session : Session) : IO (Array String) := do
  return (← session.sceneLines).filter (·.startsWith "hint ")

/-- The checks of the key hints through a host of the Vim scheme that ships
(`withVimHost`), with the real elaborator: a config's description of a
binding and its name of a prefix are in the scene's hints once it is
reloaded, and a reload that drops the name drops it from them. What the
hints list, and in which order, is pinned by `ModelTest`'s checks of the
keymap, the Vim scheme and the loop. -/
def hintChecks (context : Context) : List Check :=
  [{  name :=
        "criterion 4: after a reload, SPC lists f as the prefix config named, SPC f lists f as the binding config described, and SPC f f runs it and lists nothing"
      run :=
        withVimHost context [("10-hint.lean", hintChunk true)] fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let afterLeader ← session.hints
          session.typed "<Escape>"
          session.typed "SPC f"
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
        withVimHost context [("10-hint.lean", hintChunk true)] fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let named ← session.hints
          session.typed "<Escape>"
          session.write "10-hint.lean" (hintChunk false)
          session.ask [.reload]
          session.typed "SPC"
          let unnamed ← session.hints
          return named.contains "hint f: prefix \"file\" 1" &&
              unnamed.contains "hint f: prefix - 1" &&
              !unnamed.any (·.startsWith "hint f: prefix \"file\"") }]

end ConfigTest
