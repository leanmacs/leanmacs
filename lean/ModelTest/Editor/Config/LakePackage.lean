import Editor.Config.LakePackage
import ModelTest.Check

/-!
# Model tests: `Editor/Config/LakePackage.lean`

The model tests of `Editor/Config/LakePackage.lean`: `lakePackageChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Config

/-- The checks of the config directory as a Lake package
(`Editor/Config/LakePackage.lean`): the generated lakefile's text, and what
is done about the two files given what the directory holds. -/
def lakePackageChecks : List Check :=
  let set : LakePackage.Set :=
    { name := "default-set", directory := "/w/packages", core := "/w/lean" }
  let pin := "leanprover/lean4:v4.35.0\n"
  [{  name :=
        "the generated lakefile names the package config, requires the set by its Lake name and its directory, then editor-core by the running editor's core directory, last, so it takes precedence, and declares the library Config of every module under it"
      run :=
        pure
          (LakePackage.lakefile set ==
            "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n[[require]]\nname = \"editor-core\"\npath = \"/w/lean\"\n\n[[lean_lib]]\nname = \"Config\"\nglobs = [\"Config.+\"]\n") },
    { name := "an editor's set is known only when both its set directory and its core directory are"
      run :=
        let origin : LakePackage.Origin := { setName := "default-set", pin }
        pure
          (origin.set (some "/w/packages") (some "/w/lean") == some set &&
            origin.set none (some "/w/lean") == none &&
            origin.set (some "/w/packages") none == none) },
    { name :=
        "a set directory with a backslash or a double quote in it is written as a TOML basic string, each with a backslash before it"
      run :=
        pure
          (LakePackage.quoted "/w/a \"b\"\\c" == "\"/w/a \\\"b\\\"\\\\c\"" &&
            LakePackage.quoted "/w/packages" == "\"/w/packages\"") },
    { name :=
        "a directory that holds neither file gets both: the lakefile for the set, then the toolchain file holding the pin"
      run :=
        pure
          (LakePackage.actions pin (some set) { lakefile := false, toolchain := none } ==
            #[.create "lakefile.toml" (LakePackage.lakefile set), .create "lean-toolchain" pin]) },
    { name := "a directory that holds both files, the toolchain file naming the pin, gets nothing"
      run :=
        pure
          (LakePackage.actions pin (some set) { lakefile := true, toolchain := some pin } == #[] &&
            LakePackage.actions pin (some set)
                { lakefile := true, toolchain := some "leanprover/lean4:v4.35.0" } ==
              #[]) },
    { name :=
        "a file that is there is left: a directory with a lakefile gets the toolchain file alone, and one with a toolchain file the lakefile alone"
      run :=
        pure
          (LakePackage.actions pin (some set) { lakefile := true, toolchain := none } ==
              #[.create "lean-toolchain" pin] &&
            LakePackage.actions pin (some set) { lakefile := false, toolchain := some pin } ==
              #[.create "lakefile.toml" (LakePackage.lakefile set)]) },
    { name :=
        "a toolchain file that names another toolchain than the pin is a warning that names both, and the file is left"
      run :=
        pure
          (match
            LakePackage.actions pin (some set)
              { lakefile := true, toolchain := some "leanprover/lean4:v4.20.0\n" } with
          | #[.warn message] =>
            (message.splitOn "leanprover/lean4:v4.20.0").length == 2 &&
              (message.splitOn "leanprover/lean4:v4.35.0").length == 2 &&
              (message.splitOn "\n").length == 1
          | _ => false) },
    { name :=
        "an editor that knows no set directory, or no core directory, creates the toolchain file alone, and says as information that no lakefile is generated, naming both directories"
      run :=
        pure
          (match LakePackage.actions pin none { lakefile := false, toolchain := none } with
          | #[.inform message, .create "lean-toolchain" text] =>
            text == pin && (message.splitOn "lakefile.toml").length == 2 &&
              (message.splitOn "directory of its core or of the package set").length == 2
          | _ => false) },
    { name := "an editor that knows no set directory says nothing of a lakefile that is there"
      run :=
        pure (LakePackage.actions pin none { lakefile := true, toolchain := some pin } == #[]) }]

end ModelTest
