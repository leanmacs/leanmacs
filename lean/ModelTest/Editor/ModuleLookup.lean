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
in a bundle; outside one no toolchain, and every `.olean` directory the build
recorded for the executable, or none; a directory argument read as
directories joined with `:`, used before the recorded ones outside a bundle
and in place of the bundle's in one; the record, read through a
reader; and the directory of the set the executable was built from, by its
own record outside a bundle and by the bundle's layout in one. -/
def moduleLookupChecks : List Check :=
  let bundled (bundle : String) : ModuleLookup.Directories :=
    { sysroot := some s!"{bundle}/Contents/Resources/lean/toolchain"
      oleans := [s!"{bundle}/Contents/Resources/lean/editor"] }
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
        "an executable outside a bundle has no toolchain, and its .olean files are searched in every directory the build recorded for it, in the record's order, wherever the executable is"
      run :=
        let outside (appPath : String) : Bool :=
          ModuleLookup.resolve appPath {} recorded == { sysroot := none, oleans := recorded }
        pure
          (outside built && outside "/x/Contents/bin/editor" && outside "/x/MacOS/editor" &&
            outside "/x/Contents/MacOS/sub/editor") },
    { name :=
        "an executable outside a bundle with no record has no .olean directory: none is guessed from where the executable is"
      run :=
        pure
          (ModuleLookup.resolve built {} == { sysroot := none, oleans := [] } &&
            ModuleLookup.resolve "/opt/leanmacs/bin/editor" { sysroot := some "/s" } ==
              { sysroot := some "/s", oleans := [] }) },
    { name := "an executable in a bundle uses the bundle's directories whatever a record says"
      run :=
        pure (ModuleLookup.resolve installed {} recorded == bundled "/Applications/Leanmacs.app") },
    { name :=
        "a directory argument names the directories it joins with a colon, in order, and one directory when it holds no colon; an empty part names none"
      run :=
        pure
          (ModuleLookup.searchPath "/o" == ["/o"] &&
            ModuleLookup.searchPath "/a/lib:/b c/lib:/d" == ["/a/lib", "/b c/lib", "/d"] &&
            ModuleLookup.searchPath "/a::/b:" == ["/a", "/b"] &&
            ModuleLookup.searchPath "" == []) },
    { name :=
        "outside a bundle the directories given are searched first, each one a colon joins, then every directory recorded; with no record they are the ones given alone"
      run :=
        pure
          (ModuleLookup.resolve built { sysroot := some "/s", oleans := some "/o" } recorded ==
              { sysroot := some "/s", oleans := "/o" :: recorded } &&
            ModuleLookup.resolve built { oleans := some "/o:/p" } recorded ==
              { sysroot := none, oleans := ["/o", "/p"] ++ recorded } &&
            ModuleLookup.resolve built { sysroot := some "/s", oleans := some "/o:/p" } ==
              { sysroot := some "/s", oleans := ["/o", "/p"] } &&
            ModuleLookup.resolve built { sysroot := some "/s" } recorded ==
              { sysroot := some "/s", oleans := recorded }) },
    { name :=
        "in a bundle the directories given are used in place of the bundle's, each on its own, and nothing recorded is added: a bundle's one directory holds every module"
      run :=
        let both : ModuleLookup.Given := { sysroot := some "/s", oleans := some "/o:/p" }
        pure
          (ModuleLookup.resolve installed both recorded ==
              { sysroot := some "/s", oleans := ["/o", "/p"] } &&
            ModuleLookup.resolve installed { sysroot := some "/s" } ==
              { bundled "/Applications/Leanmacs.app" with sysroot := some "/s" } &&
            ModuleLookup.resolve installed { oleans := some "/o" } ==
              { bundled "/Applications/Leanmacs.app" with oleans := ["/o"] }) },
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
            read installed record == ([], [])) },
    { name :=
        "an executable outside a bundle started with --shipped <bundle>/Contents/MacOS/editor takes that bundle's toolchain when none is given; a given one, or a shipped default outside a bundle, wins"
      run :=
        let perUser := "/d/editors/c0/2/editor"
        let shipped := some "/Applications/Leanmacs.app/Contents/MacOS/editor"
        pure
          ((ModuleLookup.resolve perUser {} ["/d/editors/c0/2/lib/lean"] shipped).sysroot ==
              some "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain" &&
            (ModuleLookup.resolve perUser { sysroot := some "/s" } [] shipped).sysroot ==
              some "/s" &&
            (ModuleLookup.resolve perUser {} [] (some "/w/editor")).sysroot == none) },
    { name :=
        "a relative line of the record names a directory under the executable's own, so a per-user install can be renamed into place; an absolute line is kept as it is"
      run :=
        let reader (files : List (String × String)) (path : System.FilePath) : Id (Option String) :=
          pure ((files.find? (·.1 == path.toString)).map (·.2))
        let installedAt := "/d/editors/c0ffee/2/editor"
        let record := [(s!"{installedAt}.oleans", "lib/lean\n/abs/lib\n")]
        pure
          (Id.run (ModuleLookup.recorded installedAt (reader record)) ==
              ["/d/editors/c0ffee/2/lib/lean", "/abs/lib"] &&
            ModuleLookup.recordedAt installedAt "lib/lean\n" == ["/d/editors/c0ffee/2/lib/lean"]) },
    { name :=
        "the record of an executable's set is the file <executable>.set, and the directory it names is its first line that is not empty"
      run :=
        pure
          (ModuleLookup.setRecordPath built == "/w/packages/.lake/build/bin/editor.set" &&
            ModuleLookup.setRecordedIn "/w/packages\n" == some "/w/packages" &&
            ModuleLookup.setRecordedIn "\n/w/my set\n/other\n" == some "/w/my set" &&
            ModuleLookup.setRecordedIn "" == none &&
            ModuleLookup.setRecordedIn "\n" == none) },
    { name :=
        "the set directory of an executable outside a bundle is the one its record names, when that is a directory that is there; with no record, or a record that names a directory that is gone, there is none"
      run :=
        let directory (files : List (String × String)) (directories : List String) :
          Option String :=
          Id.run
            (ModuleLookup.setDirectory? built
              (fun path => pure ((files.find? (·.1 == path.toString)).map (·.2))) fun path =>
              pure (directories.contains path.toString))
        let record := [(s!"{built}.set", "/w/packages\n")]
        pure
          (directory record ["/w/packages"] == some "/w/packages" &&
            directory [] ["/w/packages"] == none &&
            directory record [] == none) },
    { name :=
        "the set directory of an executable in a bundle is Contents/Resources/lean/set when the bundle holds that directory, and none when it does not; no record is read"
      run :=
        let directory (directories : List String) : Option String × List String :=
          Id.run
            ((ModuleLookup.setDirectory? (m := StateM (List String)) installed
                  (fun path => do
                    modify (· ++ [path.toString])
                    return some "/elsewhere\n")
                  fun path => pure (directories.contains path.toString)).run
              [])
        let inBundle := "/Applications/Leanmacs.app/Contents/Resources/lean/set"
        pure
          (directory [inBundle] == (some inBundle, []) && directory ["/elsewhere"] == (none, [])) }]

end ModelTest
