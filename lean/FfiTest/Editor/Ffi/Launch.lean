import Editor.Ffi.Launch
import FfiTest.Check

/-!
# FFI tests: `Editor/Ffi/Launch.lean`

The tests of `Editor/Ffi/Launch.lean`: `ffiLaunchChecks`. The root module
`FfiTest` runs them, and each list's own doc says what it checks.

A successful exec cannot run inside `ffi-test`, which it would replace: the
launcher's Rust contract (`crates/editor-launch-std/tests/contract.rs`) and
the gate's restart fixtures (`tests/headless/restart`) pin that.
-/

namespace FfiTest

/-- The checks of the exec and of the main bundle
(`Editor/Ffi/Launch.lean`). -/
def ffiLaunchChecks (_ : Unit) : List Check :=
  [{  name :=
        "an exec of a program that is not there answers a reason naming it, and the process carries on"
      run := do
        let reason ← Editor.Ffi.exec "/nonexistent/leanmacs-ffi-exec" #["a"]
        return reason.startsWith "/nonexistent/leanmacs-ffi-exec: " },
    { name :=
        "the main bundle is the directory of ffi-test with no identifier on macOS, outside any bundle, and none elsewhere"
      run := do
        let main ← Editor.Ffi.mainBundle
        if System.Platform.isOSX then
          return match main with
            | some (_, none) => true
            | _ => false
        else
          return main.isNone }]

end FfiTest
