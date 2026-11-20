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
its packages, and a rev set, each made with the core's require written at
the root (`withCoreEdit`), which Lake reads as the last require, by the
running core's directory; and a lakefile that names the core from git
after the set, repaired. -/
def packageSetEditChecks (_ : Unit) : List Check :=
  let lakefile :=
    "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n# Mine.\n[[require]]\nname = \"hello\"\npath = \"../hello\"\n\n[[lean_lib]]\nname = \"Config\"\nglobs = [\"Config.+\"]\n"
  let core := "/w/lean"
  let own : Require := { name := "editor-core", source := .path core }
  let read (text : String) : IO (Option (Array Require)) :=
    return (← Config.Lakefile.Toml.requireEntries text).toOption
  let after (edited : Except String String) (expected : Array Require) : IO Bool := do
    match edited with
    | .ok text =>
      return (← read text) == some expected
    | .error _ =>
      return false
  [{  name :=
        "each edited lakefile is read back by Lake's loader as requiring exactly what the edit meant, then the running core, last, by its directory"
      run := do
        let some required ← read lakefile | return false
        let setRequired : Array Require :=
          #[{ name := "editor-core", source := .path "../lean" },
            { name := "shipped-themes", source := .path "shipped-themes" },
            { name := "compile", source := .path "compile" }]
        let git : Require := { name := "g", source := .git "https://h/g" (some "v1") (some "s") }
        let reservoir : Require := { name := "b", source := .reservoir "lc" (some "1.0") }
        let edit := withCoreEdit (some core) lakefile required
        let installedGit := edit (install · · git)
        let gitText := (installedGit.toOption).getD ""
        let some gitRequired ← read gitText | return false
        return (←
              after (edit (install · · { name := "x", source := .path "/p/x" }))
                  ((required.push { name := "x", source := .path "/p/x" }).push own)) &&
            (← after installedGit ((required.push git).push own)) &&
            (← after (edit (install · · reservoir)) ((required.push reservoir).push own)) &&
            (←
              after (edit (remove · · "hello" "/c" (some "default-set") setRequired))
                  #[required[0]!, own]) &&
            (←
              after (edit (remove · · "compile" "/c" (some "default-set") setRequired))
                  #[{ name := "shipped-themes", source := .path "/w/packages/shipped-themes" },
                    required[1]!, own]) &&
            (←
              after (withCoreEdit (some core) gitText gitRequired (setRev · · "g" "v2"))
                  ((required.push
                        { git with source := .git "https://h/g" (some "v2") (some "s") }).push
                    own)) },
    { name :=
        "a lakefile that names the core from git after the set is read back, once repaired, as requiring the running core last and no other editor-core"
      run := do
        let text :=
          "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n[[require]]\nname = \"editor-core\"\ngit = \"https://h/leanmacs\"\nsubDir = \"lean\"\nrev = \"nightly-1\"\n"
        let some required ← read text | return false
        match withCore text required core with
        | .ok (repaired, _) =>
          return (← read repaired) ==
              some #[{ name := "default-set", source := .path "/w/packages" }, own]
        | .error _ =>
          return false }]

end ConfigTest
