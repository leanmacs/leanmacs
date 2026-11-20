import Editor.Api
import Editor.Package

/-!
# The fixture package `broken-link`

A package that elaborates and does not link: its command calls
`noSuchSymbol`, bound to a C symbol nothing defines,
`leanmacs_no_such_symbol`, so a set that requires it fails at the link,
the linker naming the symbol, and the editor that asked keeps running
(tools/user-sets-test.sh, A).
-/

namespace BrokenLink

/-- A C function nothing defines. -/
@[extern "leanmacs_no_such_symbol"]
opaque noSuchSymbol : Unit → UInt32

/-- The package `broken-link`: a command that calls it. -/
def package : Editor.Package :=
  { name := "broken-link"
    setup := Editor.command "broken-link" (Editor.message s!"{noSuchSymbol ()}") }

end BrokenLink
