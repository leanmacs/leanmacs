import Editor.Api
import Editor.Package

/-!
# The fixture package `hello-init`

A package installed into a user's set by `:package-install`
(tools/bundle-bench.sh times that build): its `initialize` sets `helloInitText`, and its
command `hello-init` says `hello-init: <that text>`, so the command's
answer shows both that the package is linked and that its `initialize`
ran. A config file that imports `HelloInit` loads only in an editor that
links it.
-/

namespace HelloInit

/-- What this module's `initialize` sets. -/
initialize helloInitText : String ← pure "initialize ran"

/-- The package `hello-init`: the command `hello-init`. -/
def package : Editor.Package :=
  { name := "hello-init"
    setup := Editor.command "hello-init" (Editor.message s!"hello-init: {helloInitText}") }

end HelloInit
