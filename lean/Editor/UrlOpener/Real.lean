import Editor.Ffi.UrlOpener
import Editor.UrlOpener

/-!
# The URL opener's real binding

The handler of the URL opener port's requests (`Editor/UrlOpener.lean`)
over an opener the Rust library holds (`Editor.Ffi.UrlOpener`): the
library's recording opener, its failing one, or the desktop's. A URL the
system took is answered `.ok`, and a refusal `.error` with the library's
reason; a thrown error of the binding is answered as a refusal too, so a
job is never failed by it.

Only the window mode makes the desktop's opener (`Real.system`,
`Editor/Window/Real.lean`). Every other host is handed `UrlOpener.absent`.

This module is imported by the window mode and the contract checks, never
by `Editor`, as the other real bindings are kept out of the model tests'
reach. `contract-test` holds it to the job port's URL opener properties
over the library's recording and failing openers
(`ContractTest.urlOpenerJobFailures`), so the gate launches nothing, and
`ContractTest.urlOpenerChecks` pins what crosses the boundary.
-/

namespace Editor.UrlOpener

/-- An opener of the library's, answered through the port. -/
structure Real where
  /-- The library's opener. -/
  opener : Ffi.UrlOpener

namespace Real

/-- A binding over the desktop's URL opener. Only the window mode makes it. -/
def system : IO Real :=
  return { opener := ← Ffi.UrlOpener.system }

/-- A binding over a new recording opener of the library's: the fake that
launches nothing, for tests. -/
def recording : IO Real :=
  return { opener := ← Ffi.UrlOpener.recording }

/-- A binding over a new opener of the library's whose every open fails
with `reason`: the refusal's fake, for tests. -/
def failing (reason : String) : IO Real :=
  return { opener := ← Ffi.UrlOpener.failing reason }

/-- For a binding over a recording opener, each URL it was handed, in order;
`none` for any other. -/
def opened (real : Real) : IO (Option (Array String)) := do
  let some raw ← real.opener.openedRaw | return none
  -- Each URL is followed by a NUL byte, which no URL it took holds.
  let parts := raw.splitOn "\x00"
  return some (parts.dropLast.toArray)

/-- Answers `request` through the library: `.ok` once the system took the
URL, and the reason it was refused otherwise, a thrown error among them. -/
def handle (real : Real) : UrlOpenerHandler := fun request =>
  match request with
  | .openUrl url => do
    try
      return match ← real.opener.openUrl url with
        | none => .ok ()
        | some reason => .error reason
    catch error =>
      return .error s!"{error}"

end Real

end Editor.UrlOpener
