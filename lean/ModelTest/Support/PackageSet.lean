import Editor.PackageSet.Edit
import Editor.PackageSet.Running

/-!
# Model tests: support: PackageSet

What a running editor knows of its own package set, and the facts a reload
reads of a config, as the package-set checks build them: the shipped
default at `/w/packages`, its core at `/w/lean`, its config directory `/c`
and data directory `/d`, and the generated lakefile (or the one generated
before it required the core at its root) with more requires after its
own, or a repaired lakefile with the core's require after them. Shared
by the test modules of `Editor/PackageSet/Build.lean` and
`Editor/Config/Reload.lean`; it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.PackageSet

namespace PackageSetTest

/-- The shipped set's directory. -/
def setDirectory : String :=
  "/w/packages"

/-- The directory of the running editor's core. -/
def coreDirectory : String :=
  "/w/lean"

/-- The running editor of the checks: the shipped default, with its
records, its `lake`, the config directory `/c` and the data directory
`/d`, whose last reload read `facts`. -/
def runningWith (facts : Facts) (data : Option String := some "/d")
    (lake : Option String := some "/t/bin/lake") : Running :=
  { executable := "/w/packages/.lake/build/bin/editor", config := "/c"
    fingerprint := some (shipped "default-set" setDirectory), core := some "c0"
    coreDirectory := some coreDirectory
    build := #[("LEAN_CC", "/usr/bin/cc")], sysroot := some "/t", lake, data, facts }

/-- The generated lakefile's requires: the set, then the running core. -/
def generated : Array Require :=
  #[{ name := "default-set", source := .path setDirectory },
    { name := "editor-core", source := .path coreDirectory }]

/-- The requires of the lakefile generated before the core was required at
the root: the set alone. -/
def setOnly : Array Require :=
  #[{ name := "default-set", source := .path setDirectory }]

/-- A lakefile of `required`, then `more`, as the facts a reload reads. -/
def lakefileOf (required : Array Require) (more : Array Require) : Facts :=
  let text :=
    "name = \"config\"\n\n" ++
      String.join
        ((required ++ more).toList.map fun require =>
          "\n".intercalate require.table.toList ++ "\n\n")
  { lakefile := .toml text (required ++ more)
    setRequires :=
      #[{ name := "editor-core", source := .path "../lean" },
        { name := "shipped-themes", source := .path "shipped-themes" },
        { name := "compile", source := .path "compile" }] }

/-- The generated lakefile with `more` after its requires. -/
def lakefileWith (more : Array Require := #[]) : Facts :=
  lakefileOf generated more

/-- The lakefile generated before the core was required at the root, with
`more` after its one require. -/
def setOnlyLakefileWith (more : Array Require := #[]) : Facts :=
  lakefileOf setOnly more

/-- The lakefile with the set's require, `more`, and the running core's
require last, as every package command writes it. -/
def repairedLakefileWith (more : Array Require := #[]) : Facts :=
  lakefileOf (setOnly ++ more) #[{ name := "editor-core", source := .path coreDirectory }]

/-- The package `hello` by path. -/
def hello : Require :=
  { name := "hello", source := .path "/h" }

end PackageSetTest

end ModelTest
