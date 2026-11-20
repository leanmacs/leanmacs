import Editor.Api
import Editor.Package

/-!
# The fixture package `c-glue`

A package that brings native code through a C FFI (`c/cglue.c`): the
command `c-glue` says `c-glue: <what the C function answers>`.
-/

namespace CGlue

/-- The C function of `c/cglue.c`. -/
@[extern "leanmacs_cglue_answer"]
opaque answer : Unit → UInt32

/-- The package `c-glue`: the command `c-glue`. -/
def package : Editor.Package :=
  { name := "c-glue"
    setup := Editor.command "c-glue" (Editor.message s!"c-glue: {answer ()}") }

end CGlue
