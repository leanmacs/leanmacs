import Editor.Extension
import Editor.Process.Environment
import Editor.Setup
import EnvironmentApi

/-!
# The login shell, as the base of a child's environment

The user's shell, run as a login shell in the home directory, printing its
environment, as a base of the core's interface library `environment-api`
(`EnvironmentApi.BaseSource`, `lean/EnvironmentApi.lean`): the core sets
what it prints over the editor's own environment, under every directory
source, once per run (`Editor/Process/Environment.lean`). The value the
package registers is `baseSource`, named `login-shell`, which the package
chooses as the default base (`LoginShell/Compiled.lean`); config's setting
is `LoginShell.timeLimit`.

Started from Finder, the editor's own environment is launchd's, whose
`PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`: a tool the user installed
outside mise, such as Homebrew's, is on no child's `PATH` without this base.

## The rules

- **Which shell.** `SHELL` from the editor's environment, else the user's
  login shell from the system's user record, else `/bin/zsh`
  (`fallbackShell`). The first two are probes the core runs through the
  process service (`shellProbes`, `Process.Program.probed`): `printenv
  SHELL`, which inherits the editor's environment and exits 1 with
  `SHELL` unset, and `id -P`, whose passwd line ends with the login shell.
  A probe that fails, or names no absolute path, passes to the next, and
  nothing is said of it. What they find is kept until a reload.
- **The command** (`lookupCommand`): `<shell> -l -c <printCommand>` in the
  home directory (`/` with no `HOME`), over the editor's own environment.
  It is a login shell, so it reads the user's profile, and
  non-interactive: an interactive shell (`-i`) expects a terminal, so it is
  never run. The command prints a start marker, the environment
  NUL-separated (`env -0`), and an end marker, each by an absolute
  program, so it runs whatever `PATH` the profile leaves, and reads the
  same in sh, zsh, bash and fish.
- **What is read** (`parse`): the variables between the first start marker
  and the first end marker that starts right after the start marker or
  right after a NUL, so a value that holds the marker's text cannot end
  them. What rc files print before and after the markers is ignored,
  whatever its bytes: the markers are found in the bytes, and only the
  variables between them are read as UTF-8. Each piece is `NAME=value`,
  split at its first `=`; a value keeps any later `=` and any newline.
- **What is kept.** Every variable but the shell's own per-session ones,
  `PWD`, `OLDPWD`, `SHLVL` and `_` (`sessionVariables`), which describe
  that shell, not the editor. A name that comes twice keeps its last
  value.
- **When it runs.** Once per run, the first time a child is prepared, under
  the core's base cache; again after a reload that installs. A child
  prepared after that gets the kept variables.
- **The limits.** The lookup and the probes run with a time limit of 5 s
  (`defaultLimit`) and the core's output limit (`Process.lookupOutput`).
  The setting `LoginShell.timeLimit (milliseconds)` in config registers the
  same base with that limit, which replaces the package's (the latest
  value of a name wins, `EnvironmentApi.BaseSource.choose`). `0` is
  refused (`zeroLimit`), and so is a second call in one `setup`
  (`Extension.setting`, `Config.Registrations.settingTwice`).
- **When it fails** (no shell where the probes point, a status other than
  0, output with no markers, variables that are not UTF-8, a run past its
  limit), children get the editor's own environment (launchd's), still
  under every directory source, and the echo area says why once per run,
  in the core's words
  (`Process.failureMessage (.base "login-shell")`).
- **The headless mode looks nothing up**: the base is `.inherited` there, so
  the headless fixtures and every test start their children over the
  editor's own environment, and no test runs the user's shell.
- **Opting out.** `environmentBase "inherited"` in config chooses the core's
  base, launchd's environment, over the package's default; leaving the
  package out of the set does the same.
- **mise over it.** A directory source's lookup runs over the base's
  variables (the core's layering), so mise's lookup sees the shell's
  `PATH`; mise itself is still found at its fixed places
  (`packages/mise/Mise.lean`). mise's own `PATH` entries come first in what
  it prints, so a project's pinned tool still wins over the shell's.

Pinned by `LoginShellTest.loginShellChecks` and
`LoginShellTest.loginShellLookupChecks` on the models, and over the real
process service, with fixtures in place of a shell, by
`LoginShellTest.Linked.loginShellContractChecks` (the base contract) and
`LoginShellTest.Linked.loginShellWiringChecks` (a real base under a real
directory source). That a child gets the environment its command was
prepared with is the core's (`ModelTest.environmentLayerChecks`) and the job
port's process contract's (`JobContract.processProperties`), not pinned
here. That the default set registers the package and chooses its base in
the window mode is the standing fixture
`tests/headless/environment-sources`'s, on the default set's harness.
-/

namespace LoginShell

open Editor

/-- The name the package's base answers to (`environmentBase`). -/
def name : String :=
  "login-shell"

/-- How long the lookup and each probe may run by default, in milliseconds. -/
def defaultLimit : Nat :=
  5000

/-- The shell run when no probe names one. -/
def fallbackShell : System.FilePath :=
  "/bin/zsh"

/-- What the lookup prints right before the environment. -/
def beginMarker : String :=
  "EDITOR-LOGIN-SHELL-ENVIRONMENT-BEGIN"

/-- What the lookup prints right after the environment. -/
def endMarker : String :=
  "EDITOR-LOGIN-SHELL-ENVIRONMENT-END"

/-- The command the login shell runs: the start marker, the environment
NUL-separated, then the end marker, each by an absolute program. -/
def printCommand : String :=
  s!"/usr/bin/printf %s {beginMarker}; /usr/bin/env -0; /usr/bin/printf %s {endMarker}"

/-- The lookup's command: `shell -l -c printCommand` in `directory`, with
`environment` set over the editor's. Never `-i`: an interactive shell
expects a terminal. -/
def lookupCommand (shell directory : System.FilePath) (environment : Process.Environment := {}) :
    Process.Command :=
  { program := shell.toString, arguments := #["-l", "-c", printCommand], directory, environment }

/-- The variables the login shell sets for itself alone, which are not
kept. -/
def sessionVariables : Array String :=
  #["PWD", "OLDPWD", "SHLVL", "_"]

/-- Whether `pattern`'s bytes occur in `bytes` at `offset`. -/
def bytesAt (bytes pattern : ByteArray) (offset : Nat) : Bool :=
  offset + pattern.size ≤ bytes.size &&
    (List.range pattern.size).all fun index => bytes[offset + index]! == pattern[index]!

/-- The first offset at or after `start` where `pattern` occurs in `bytes`,
or `none`. -/
def findBytes (bytes pattern : ByteArray) (start : Nat := 0) : Option Nat :=
  (List.range' start (bytes.size + 1 - start)).find? (bytesAt bytes pattern ·)

/-- The bytes after the first `beginMarker` in `bytes`, or `none`. -/
def afterBegin (bytes : ByteArray) : Option ByteArray := do
  let offset ← findBytes bytes beginMarker.toUTF8
  pure (bytes.extract (offset + beginMarker.utf8ByteSize) bytes.size)

/-- The variables' bytes at the start of `rest`, up to the first `endMarker`
that starts it or follows a NUL, without that NUL; `none` with no such
marker. -/
def beforeEnd (rest : ByteArray) : Option ByteArray :=
  if bytesAt rest endMarker.toUTF8 0 then some .empty
  else (findBytes rest (String.singleton (Char.ofNat 0) ++ endMarker).toUTF8).map (rest.extract 0 ·)

/-- `piece`, `NAME=value`, split at its first `=`; refused with no `=` or
an empty name. -/
def variableOf (piece : String) : Except String (String × String) :=
  match piece.splitOn "=" with
  | name :: value@(_ :: _) =>
    if name.isEmpty then throw s!"the piece {piece.quote} has no name"
    else pure (name, "=".intercalate value)
  | _ => throw s!"the piece {piece.quote} is not NAME=value"

/-- The variables the login shell's output `bytes` holds: the NUL-separated
`NAME=value` pieces between the first `beginMarker` and the first
`endMarker` that starts right after it or right after a NUL, in order, a
name that comes twice keeping its last value, without `sessionVariables`.
What comes before and after the markers is ignored. The markers are found
in the bytes, and only the bytes between them are decoded, so what comes
before and after them may be any bytes. Output that has no start marker, or
no end marker after its variables, variables that are not UTF-8, or a piece
that is not `NAME=value`, is refused, with why. -/
def parse (bytes : ByteArray) : Except String (Array (String × String)) := do
  let some rest := afterBegin bytes | throw "it holds no start marker"
  let some block := beforeEnd rest | throw "it holds no end marker after its variables"
  let some text := String.fromUTF8? block | throw "it is not UTF-8"
  let pieces := if text.isEmpty then [] else text.splitOn (String.singleton (Char.ofNat 0))
  pieces.foldlM
      (fun kept piece => do
        let (named, value) ← variableOf piece
        return if sessionVariables.contains named then kept else Process.setLast kept named value)
      #[]

/-- What the lookup's output must be, for a person. -/
def output : String :=
  "the environment, NUL-separated between its markers"

/-- The probes that find the shell, in order: `printenv SHELL`, which
prints the editor's `SHELL`, then `id -P`, the user's record from the
directory service, whose last `:` field is the login shell. -/
def shellProbes : Array Process.Probe :=
  #[{ command := { program := "/usr/bin/printenv", arguments := #["SHELL"], directory := "/" }
      answer := .line },
    { command := { program := "/usr/bin/id", arguments := #["-P"], directory := "/" }
      answer := .lastField ':' }]

/-- Where the shell is: the first path `shellProbes` names, else
`fallbackShell`. -/
def program : Process.Program :=
  .probed shellProbes fallbackShell

/-- The login shell at `program` as a source, its lookup and probes limited
to `limit` milliseconds. -/
def source (program : Process.Program) (limit : Nat := defaultLimit) : Process.Source :=
  { name, program
    command := fun shell directory environment => lookupCommand shell directory environment
    parse, output, limit := some limit }

/-- The package's base: in the window mode the login shell found by
`program`, looked up in the home directory, or `/` with none, within
`limit` milliseconds; in the headless mode, no lookup. -/
def baseSource (limit : Nat := defaultLimit) : EnvironmentApi.BaseSource :=
  { name
    base := fun
      | .headless => .inherited
      | .window home => .lookup (source program limit) (home.getD "/") }

/-- The login shell at `shell`, looked up in `home` within `limit`
milliseconds, in every mode: for tests, and for a set that names its shell.
It is not a config setting. -/
def «at» (shell home : System.FilePath) (limit : Nat := defaultLimit) : EnvironmentApi.BaseSource :=
  { name, base := fun _ => .lookup (source (.at shell) limit) home }

/-- What `LoginShell.timeLimit 0` is refused with. -/
def zeroLimit : String :=
  "the login shell's time limit must be at least 1 ms"

/-- The package's setting, called in config: the login shell's lookup and
probes may run for `milliseconds`, in place of 5 s. It registers a base of
the name `login-shell`, which replaces the package's. Refuses the `setup`
for `0`, and, as the core's settings are, for calling it twice
(`Extension.setting`). -/
def timeLimit (milliseconds : Nat) : SetupM Unit := do
  if milliseconds == 0 then
    throw zeroLimit
  Extension.setting "LoginShell.timeLimit" (baseSource milliseconds)

end LoginShell
