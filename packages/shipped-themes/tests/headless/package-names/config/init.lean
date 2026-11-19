import Editor
import ShippedThemes
open Editor

-- A config that names a declaration of this package, `ShippedThemes.themes`,
-- so it elaborates only on a base that holds the package's modules: the
-- editor's base is its package set's, `Editor` and then the entry module of
-- each package of the set outside the core.

/-- Says the names of the themes the package ships, in the echo area. -/
def shippedNames : EditorM Unit :=
  message s!"the package ships {ShippedThemes.themes.map (·.name)}"

def setup : SetupM Unit := do
  command "shipped-theme-names" shippedNames
