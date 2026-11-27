import LoginShellTest.Check
import LoginShellTest.LoginShell

/-!
# The test driver of the package `login-shell`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

The test module mirrors the modules it tests: the checks of
`LoginShell.lean` and `LoginShell/Compiled.lean` are in
`LoginShellTest/LoginShell.lean`.

- `loginShellChecks`: the package registers one base named `login-shell`
  and chooses it as its default base; chosen, it is inherited in the
  headless mode and in the window mode the login shell its probes find,
  else `/bin/zsh`, looked up in the home directory within 5 s; config's
  `environmentBase "inherited"` opts out; `LoginShell.timeLimit` replaces
  the limit, refuses 0 and a second call; the lookup's command, never
  interactive, and the probes; the parser (criterion 1): the
  NUL-separated variables between the markers, what is around them
  ignored, the per-session variables dropped, and each refusal; and
  `environment-api`'s base contract (`EnvironmentApiTest.baseContract`) on
  the model rig.
- `loginShellLookupChecks`: a child's environment over the login shell on
  the job model, as a host installs the package's value: the shell is
  `SHELL`, else the user record's, else `/bin/zsh`; it runs once per run,
  the first time a child is prepared, and again after a reload; the
  headless mode runs nothing; a shell that exits non-zero, prints no
  markers, outlives its limit (the package's or config's) or is not there
  leaves children on the editor's own environment, said once (criterion
  2); and a directory source runs over the shell's variables, its `PATH`
  first.
-/

/-- Every check of the test driver, in the order they run. -/
def LoginShellTest.checks : List LoginShellTest.Check :=
  LoginShellTest.loginShellChecks ++ LoginShellTest.loginShellLookupChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← LoginShellTest.failures LoginShellTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"login-shell-test: {LoginShellTest.checks.length} checks passed"
    return 0
  else
    return 1
