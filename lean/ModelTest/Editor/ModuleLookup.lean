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
in a bundle, no toolchain and `../lib/lean` outside one, and explicit
directories over either. -/
def moduleLookupChecks : List Check :=
  let bundled (bundle : String) : ModuleLookup.Directories :=
    { sysroot := some s!"{bundle}/Contents/Resources/lean/toolchain"
      oleans := s!"{bundle}/Contents/Resources/lean/editor" }
  let installed := "/Applications/Leanmacs.app/Contents/MacOS/editor"
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
        "an executable outside a bundle has no toolchain, and its .olean files are <directory of the executable>/../lib/lean"
      run :=
        let outside (appPath directory : String) : Bool :=
          ModuleLookup.resolve appPath {} ==
            { sysroot := none, oleans := s!"{directory}/../lib/lean" }
        pure
          (outside "/opt/leanmacs/bin/editor" "/opt/leanmacs/bin" &&
            outside "/x/Contents/bin/editor" "/x/Contents/bin" &&
            outside "/x/MacOS/editor" "/x/MacOS" &&
            outside "/x/Contents/MacOS/sub/editor" "/x/Contents/MacOS/sub") },
    { name :=
        "directories given explicitly are used wherever the executable is, and each given alone overrides only its own"
      run :=
        let both : ModuleLookup.Given := { sysroot := some "/s", oleans := some "/o" }
        let given : ModuleLookup.Directories := { sysroot := some "/s", oleans := "/o" }
        pure
          (ModuleLookup.resolve installed both == given &&
            ModuleLookup.resolve "/opt/leanmacs/bin/editor" both == given &&
            ModuleLookup.resolve installed { sysroot := some "/s" } ==
              { bundled "/Applications/Leanmacs.app" with sysroot := some "/s" } &&
            ModuleLookup.resolve installed { oleans := some "/o" } ==
              { bundled "/Applications/Leanmacs.app" with oleans := "/o" } &&
            ModuleLookup.resolve "/opt/leanmacs/bin/editor" { sysroot := some "/s" } ==
              { sysroot := some "/s", oleans := "/opt/leanmacs/bin/../lib/lean" } &&
            ModuleLookup.resolve "/opt/leanmacs/bin/editor" { oleans := some "/o" } ==
              { sysroot := none, oleans := "/o" }) }]

end ModelTest
