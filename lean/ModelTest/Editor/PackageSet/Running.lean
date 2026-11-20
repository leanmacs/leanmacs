import Editor.PackageSet.Running
import ModelTest.Check

/-!
# Model tests: `Editor/PackageSet/Running.lean`

The model tests of `Editor/PackageSet/Running.lean`:
`packageSetRunningChecks`, over a fake file read and a fake test of
existence. The root module `ModelTest` runs them; its module doc says what
each shows.
-/

namespace ModelTest

open Editor
open Editor.PackageSet

namespace RunningTest

/-- What the executable at `appPath` knows, over `files` (path and text),
with the set `set` and the sysroot `/t`. -/
def runningOver (appPath : String) (files : List (String × String))
    (set : Option (String × String) := some ("default-set", "/w/packages")) : Running :=
  Id.run
    (PackageSet.at appPath "/c" set (some "/t") (some "/d")
      (fun path => pure ((files.find? (·.1 == path)).map (·.2))) fun path =>
      pure (files.any (·.1 == path)))

end RunningTest

open RunningTest in
/-- The checks of what the running editor knows of its own package set
(`Editor/PackageSet/Running.lean`): the records beside it, the shipped
fingerprint when it has no `.packages` record, the recorded one when it
has, none with neither, and the toolchain's `lake` only when it is
there. -/
def packageSetRunningChecks : List Check :=
  [{  name :=
        "an executable built from a set reads its core and build records, has the shipped fingerprint of its set, and the toolchain's lake when it is there"
      run :=
        let exe := "/w/packages/.lake/build/bin/editor"
        let running :=
          runningOver exe
            [(s!"{exe}.core", "c0ffee\n"),
              (s!"{exe}.build", "LEAN_CC=/usr/bin/cc\nMACOSX_DEPLOYMENT_TARGET=26.0\n"),
              ("/t/bin/lake", "")]
        pure
          (running ==
              { executable := exe, config := "/c",
                fingerprint := some (shipped "default-set" "/w/packages")
                core := some "c0ffee"
                build := #[("LEAN_CC", "/usr/bin/cc"), ("MACOSX_DEPLOYMENT_TARGET", "26.0")]
                sysroot := some "/t", lake := some "/t/bin/lake", data := some "/d" } &&
            running.setName == some "default-set") },
    { name :=
        "a per-user install's .packages record is its fingerprint, set name and all; with no record and no set there is none, and no lake when the toolchain has none"
      run :=
        let exe := "/d/editors/c0ffee/2/editor"
        let recorded : Fingerprint :=
          { required := #["path hello /h"], pins := #[], set := some "default-set" }
        let installed :=
          runningOver exe [(s!"{exe}.packages", recorded.text)] (set := some ("config", "/c"))
        let bare := runningOver "/x/editor" [] (set := none)
        pure
          (installed.fingerprint == some recorded && installed.setName == some "default-set" &&
            bare.fingerprint == none &&
            bare.core == none &&
            bare.lake == none) },
    { name :=
        "the core record of an executable in an app bundle is in the bundle's Contents/Resources, where codesign lets a file that is not code be; outside one it is beside the executable"
      run :=
        pure
          (coreRecordPath "/A.app/Contents/MacOS/editor" ==
              "/A.app/Contents/Resources/editor.core" &&
            coreRecordPath "/w/packages/.lake/build/bin/editor" ==
              "/w/packages/.lake/build/bin/editor.core") },
    { name :=
        "the build record of an executable in an app bundle is the bundle's Contents/Resources/editor.build, and it is the one read; outside one it is beside the executable"
      run :=
        let exe := "/A.app/Contents/MacOS/editor"
        let running :=
          runningOver exe
            [("/A.app/Contents/Resources/editor.build", "MACOSX_DEPLOYMENT_TARGET=26.0\n"),
              (s!"{exe}.build", "LEAN_CC=/usr/bin/cc\n")]
        pure
          (buildRecordPath exe == "/A.app/Contents/Resources/editor.build" &&
            buildRecordPath "/w/packages/.lake/build/bin/editor" ==
              "/w/packages/.lake/build/bin/editor.build" &&
            running.build == #[("MACOSX_DEPLOYMENT_TARGET", "26.0")]) },
    { name :=
        "a .build record's lines are NAME=value, a value may hold =, and a line with none is left out"
      run :=
        pure
          (buildIn "A=1\nB=x=y\nnothing\n=v\n" == #[("A", "1"), ("B", "x=y")] &&
            coreIn "\n  abc  \n" == some "abc" &&
            coreIn "" == none) }]

end ModelTest
