import Editor.ModuleLookup
import ModelTest.Check

/-!
# Model tests: `Editor/ModuleLookup.lean`

The model tests of `Editor/ModuleLookup.lean`: `moduleLookupChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of where the editor's Lean modules are
(`Editor/ModuleLookup.lean`): the bundle's two directories from an executable
in a bundle; outside one no toolchain, and the `.olean` directory the build
recorded for the executable, or none; explicit directories over either; and
the record, read through a reader. -/
def moduleLookupChecks : List Check :=
  let bundled (bundle : String) : ModuleLookup.Directories :=
    { sysroot := some s!"{bundle}/Contents/Resources/lean/toolchain"
      oleans := some s!"{bundle}/Contents/Resources/lean/editor" }
  let installed := "/Applications/Leanmacs.app/Contents/MacOS/editor"
  let built := "/w/packages/.lake/build/bin/editor"
  let recorded := ["/w/lean/.lake/build/lib/lean", "/w/packages/themes/.lake/build/lib/lean"]
  [{  name :=
        "an executable at <bundle>/Contents/MacOS/<name> finds the toolchain at Contents/Resources/lean/toolchain and its .olean files at Contents/Resources/lean/editor, in a renamed bundle and in one with no .app suffix too"
      run :=
        pure
          (ModuleLookup.resolve installed {} == bundled "/Applications/Leanmacs.app" &&
            ModuleLookup.resolve "/Users/ada/Apps/My Editor.app/Contents/MacOS/editor" {} ==
              bundled "/Users/ada/Apps/My Editor.app" &&
            ModuleLookup.resolve "/tmp/staged/Contents/MacOS/leanmacs" {} ==
              bundled "/tmp/staged") },
    { name :=
        "an executable outside a bundle has no toolchain, and its .olean files are in the first directory the build recorded for it, wherever the executable is"
      run :=
        let outside (appPath : String) : Bool :=
          ModuleLookup.resolve appPath {} recorded ==
            { sysroot := none, oleans := some "/w/lean/.lake/build/lib/lean" }
        pure
          (outside built && outside "/x/Contents/bin/editor" && outside "/x/MacOS/editor" &&
            outside "/x/Contents/MacOS/sub/editor") },
    { name :=
        "an executable outside a bundle with no record has no .olean directory: none is guessed from where the executable is"
      run :=
        pure
          (ModuleLookup.resolve built {} == { sysroot := none, oleans := none } &&
            ModuleLookup.resolve "/opt/leanmacs/bin/editor" { sysroot := some "/s" } ==
              { sysroot := some "/s", oleans := none }) },
    { name := "an executable in a bundle uses the bundle's directories whatever a record says"
      run :=
        pure (ModuleLookup.resolve installed {} recorded == bundled "/Applications/Leanmacs.app") },
    { name :=
        "directories given explicitly are used wherever the executable is and whatever was recorded, and each given alone overrides only its own"
      run :=
        let both : ModuleLookup.Given := { sysroot := some "/s", oleans := some "/o" }
        let given : ModuleLookup.Directories := { sysroot := some "/s", oleans := some "/o" }
        pure
          (ModuleLookup.resolve installed both == given &&
            ModuleLookup.resolve built both recorded == given &&
            ModuleLookup.resolve installed { sysroot := some "/s" } ==
              { bundled "/Applications/Leanmacs.app" with sysroot := some "/s" } &&
            ModuleLookup.resolve installed { oleans := some "/o" } ==
              { bundled "/Applications/Leanmacs.app" with oleans := some "/o" } &&
            ModuleLookup.resolve built { sysroot := some "/s" } recorded ==
              { sysroot := some "/s", oleans := some "/w/lean/.lake/build/lib/lean" } &&
            ModuleLookup.resolve built { oleans := some "/o" } recorded ==
              { sysroot := none, oleans := some "/o" }) },
    { name :=
        "the record of an executable is the file <executable>.oleans, and the directories it names are its lines that are not empty, in order"
      run :=
        pure
          (ModuleLookup.recordPath built == "/w/packages/.lake/build/bin/editor.oleans" &&
            ModuleLookup.recordedIn "/a/lib\n/b c/lib\n" == ["/a/lib", "/b c/lib"] &&
            ModuleLookup.recordedIn "/a/lib" == ["/a/lib"] &&
            ModuleLookup.recordedIn "\n/a/lib\n\n" == ["/a/lib"] &&
            ModuleLookup.recordedIn "" == []) },
    { name :=
        "the record is read through the reader it is given: the file beside the executable outside a bundle, nothing when there is none, and no file at all in a bundle"
      run :=
        let reader (files : List (String × String)) (path : System.FilePath) :
          StateM (List String) (Option String) := do
          modify (· ++ [path.toString])
          return (files.find? (·.1 == path.toString)).map (·.2)
        let record := [(s!"{built}.oleans", "/a/lib\n/b/lib\n")]
        -- The directories read, and the paths the reader was asked for.
        let read (appPath : String) (files : List (String × String)) : List String × List String :=
          Id.run ((ModuleLookup.recorded appPath (reader files)).run [])
        pure
          (read built record == (["/a/lib", "/b/lib"], [s!"{built}.oleans"]) &&
            read built [] == ([], [s!"{built}.oleans"]) &&
            read installed record == ([], [])) }]

end ModelTest
