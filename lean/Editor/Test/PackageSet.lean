import Editor.Package
import Editor.PackageSet.Build
import Editor.PackageSet.Edit
import Editor.PackageSet.Running
import Editor.Process.Model

/-!
# The test kit: PackageSet

Two things the checks of a user's package set share.

- **`buildPackage`**, a stand-in for the build half of the `package-set`
  package that the core's tests, and a package's, may register: the job
  `package-build` (`buildWork`), reported, and the two commands the job
  posts to (`startedName`, `outputName`), all the core's
  (`Editor/PackageSet/Build.lean`). The reload asks for a build and the
  host starts that job by name, so a check of the build, whose subject is
  the core, registers this and names no module of the package. It
  registers no `:package-…` command and no edit job: those are the
  package's.
- **What a running editor knows of its own package set, and the facts a
  reload reads of a config**, as the package-set checks build them: the
  shipped default at `/w/packages`, its core at `/w/lean`, its config
  directory `/c` and data directory `/d`, and the generated lakefile (or
  the one generated before it required the core at its root) with more
  requires after its own, or a repaired lakefile with the core's require
  after them; a git package, and a process script that replies.

It holds no checks. `buildPackage` is pinned by the checks that run on it
(`ModelTest.packageSetBuildChecks`), and the package's own check holds the
real package to it. The rest is shared by the test modules of
`Editor/PackageSet/Build.lean` and `Editor/Config/Reload.lean` and by the
package `package-set`'s tests.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test.PackageSet

open Editor
open Editor.PackageSet

/-- The kit's stand-in for the build half of the package `package-set`
(the module docs): the job `package-build`, reported, and the two commands
it posts to. -/
def buildPackage : Package :=
  { name := "package-set"
    setup := do
      commandWith startedName startedCommand
      commandWith outputName outputCommand
      workJob buildJob buildWork (reported := true) }

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

/-- A git package. -/
def gitPackage : Require :=
  { name := "g", source := .git "https://example.invalid/g" (some "v1") none }

/-- A run replying status `code` with `stdout`, and `stderr` on standard
error. -/
def replied (command : Process.Command) (code : Nat := 0) (stdout : String := "")
    (stderr : String := "") : Process.Script :=
  { command, reply := .ok { exit := .code code, stdout := stdout.toUTF8, stderr := stderr.toUTF8 } }

end Editor.Test.PackageSet
