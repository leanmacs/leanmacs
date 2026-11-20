import ConfigTest.Check
import Editor.Config.Lakefile.Toml
import Editor.PackageSet.Edit

/-!
# Config tests: `Editor/PackageSet/Edit.lean`

The tests of `Editor/PackageSet/Edit.lean` against Lake's own TOML loader:
`packageSetEditChecks`. Each edited text is read back with Lake's loader
(`Config.Lakefile.Toml.requireEntries`), which must see exactly the
requires the edit meant. The root module `ConfigTest` runs them; its
module doc says what each shows.
-/

namespace ConfigTest

open Editor
open Editor.PackageSet

/-- The checks of the lakefile's edits read back with Lake's loader: an
install of each kind, a remove, the default set expanded without one of
its packages, and a rev set. -/
def packageSetEditChecks (_ : Unit) : List Check :=
  let lakefile :=
    "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n# Mine.\n[[require]]\nname = \"hello\"\npath = \"../hello\"\n\n[[lean_lib]]\nname = \"Config\"\nglobs = [\"Config.+\"]\n"
  let read (text : String) : IO (Option (Array Require)) :=
    return (← Config.Lakefile.Toml.requireEntries text).toOption
  let after (edited : Except String String) (expected : Array Require) : IO Bool := do
    match edited with
    | .ok text =>
      return (← read text) == some expected
    | .error _ =>
      return false
  [{  name :=
        "each edited lakefile is read back by Lake's loader as requiring exactly what the edit meant"
      run := do
        let some required ← read lakefile | return false
        let setRequired : Array Require :=
          #[{ name := "editor-core", source := .path "../lean" },
            { name := "shipped-themes", source := .path "shipped-themes" },
            { name := "compile", source := .path "compile" }]
        let git : Require := { name := "g", source := .git "https://h/g" (some "v1") (some "s") }
        let reservoir : Require := { name := "b", source := .reservoir "lc" (some "1.0") }
        let installedGit := install lakefile required git
        let gitText := (installedGit.toOption).getD ""
        let some gitRequired ← read gitText | return false
        return (←
              after (install lakefile required { name := "x", source := .path "/p/x" })
                  (required.push { name := "x", source := .path "/p/x" })) &&
            (← after installedGit (required.push git)) &&
            (← after (install lakefile required reservoir) (required.push reservoir)) &&
            (←
              after (remove lakefile required "hello" "/c" (some "default-set") setRequired)
                  #[required[0]!]) &&
            (←
              after (remove lakefile required "compile" "/c" (some "default-set") setRequired)
                  #[{ name := "editor-core", source := .path "/w/lean" },
                    { name := "shipped-themes", source := .path "/w/packages/shipped-themes" },
                    required[1]!]) &&
            (←
              after (setRev gitText gitRequired "g" "v2")
                  (required.push
                    { git with source := .git "https://h/g" (some "v2") (some "s") })) }]

end ConfigTest
