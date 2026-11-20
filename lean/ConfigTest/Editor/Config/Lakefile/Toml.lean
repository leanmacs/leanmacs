import ConfigTest.Check
import Editor.Config.LakePackage
import Editor.Config.Lakefile
import Editor.Config.Lakefile.Toml
import Lake.Util.Casing

/-!
# Config tests: `Editor/Config/Lakefile/Toml.lean`

The tests of `Editor/Config/Lakefile/Toml.lean`: `lakefileChecks`. The root
module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- The checks of the adapter that reads a lakefile's requires with Lake's
TOML loader (`Editor/Config/Lakefile/Toml.lean`), on texts written here,
and of the core's copy of Lake's casing rule against Lake's own
(`Config.Lakefile.libraryRoot`). -/
def lakefileChecks (_ : Unit) : List Check :=
  let names (text : String) : IO (Option (Array String)) :=
    return (← Config.Lakefile.Toml.requires text).toOption
  [{ name := "the requires of a lakefile are the names of its require tables, in order",
     run := do
       let text :=
         "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n[[require]]\nname = \"greeting-loud\"\ngit = \"https://example.invalid/greeting\"\nrev = \"main\"\n\n[[lean_lib]]\nname = \"Config\"\n"
       return (← names text) == some #["default-set", "greeting-loud"] },
    { name :=
        "the lakefile the editor generates for a set is read back as requiring that set, a directory with a quote and a backslash in it too"
      run := do
        let plain :=
          Config.LakePackage.lakefile { name := "default-set", directory := "/w/packages" }
        let quoted := Config.LakePackage.lakefile { name := "my-set", directory := "/w/a \"b\"\\c" }
        return (← names plain) == some #["default-set"] && (← names quoted) == some #["my-set"] },
    { name := "a lakefile with no require requires nothing"
      run := do
        return (← names "name = \"config\"\n\n[[lean_lib]]\nname = \"Config\"\n") == some #[] },
    { name := "a require table with no name that is a string is left out"
      run := do
        let text :=
          "name = \"config\"\n\n[[require]]\npath = \"/w/a\"\n\n[[require]]\nname = 3\n\n[[require]]\nname = \"kept\"\n"
        return (← names text) == some #["kept"] },
    { name := "a text that is not TOML is an error, in one line that is not empty"
      run := do
        match ← Config.Lakefile.Toml.requires "name = \"config\n[[require" with
        | .ok _ =>
          return false
        | .error reason =>
          return !reason.isEmpty && (reason.splitOn "\n").length == 1 },
    { name :=
        "the core's rule for the library of a package is Lake's casing: the two agree on names with dashes, underscores, capitals and digits"
      run :=
        pure
          (["greeting", "greeting-loud", "shipped_themes", "editorCore", "default-set", "a-b_c-d",
                "x2-y3", "Already"].all
            fun name =>
            Config.Lakefile.libraryRoot name ==
              (Lake.toUpperCamelCase (Lean.Name.mkSimple name)).toString (escape := false)) }]

/-- The checks of the adapter's `[[require]]` tables
(`Config.Lakefile.Toml.requireEntries`), on texts written here: each
table's kind and fields, and the generated lakefile read back. -/
def lakefileEntryChecks (_ : Unit) : List Check :=
  let entries (text : String) : IO (Option (Array PackageSet.Require)) :=
    return (← Config.Lakefile.Toml.requireEntries text).toOption
  [{  name :=
        "a lakefile's require tables are path, git or Reservoir dependencies, in order, each with its fields"
      run := do
        let text :=
          "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n[[require]]\nname = \"loud\"\ngit = \"https://example.invalid/loud\"\nrev = \"main\"\nsubDir = \"pkg\"\n\n[[require]]\nname = \"bare\"\ngit = \"https://example.invalid/bare\"\n\n[[require]]\nname = \"batteries\"\nscope = \"leanprover-community\"\nversion = \"v1.2\"\n\n[[require]]\nname = \"unscoped\"\n\n[[lean_lib]]\nname = \"Config\"\n"
        return (← entries text) ==
            some
              #[{ name := "default-set", source := .path "/w/packages" },
                { name := "loud",
                  source := .git "https://example.invalid/loud" (some "main") (some "pkg") },
                { name := "bare", source := .git "https://example.invalid/bare" none none },
                { name := "batteries", source := .reservoir "leanprover-community" (some "v1.2") },
                { name := "unscoped", source := .reservoir "" none }] },
    { name := "the generated lakefile is read back as one path require of its set"
      run := do
        let text :=
          Config.LakePackage.lakefile { name := "default-set", directory := "/w/packages" }
        return (← entries text) ==
            some #[{ name := "default-set", source := .path "/w/packages" }] },
    { name := "a text that is not TOML is an error, and a table with no string name is left out"
      run := do
        let broken := (← Config.Lakefile.Toml.requireEntries "name = \"config\n[[require").toOption
        return broken.isNone && (← entries "[[require]]\nname = 3\npath = \"/a\"\n") == some #[] }]

end ConfigTest
