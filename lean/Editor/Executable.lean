import Editor.Restart.Launch

/-!
# The executable's top-level dispatch

Which mode the editor executable runs, given its command line (`mode`). It
is pure, so `model-test` pins it (`ModelTest.executableModeChecks`), and
`Editor.Main.run` (`Editor/Main.lean`) acts on what it selects.

- **The launch flags** come first: the app's launcher gives an editor
  `--launched-by`, `--shipped`, `--restore`, `--handed-over` and `--failed`
  before anything else (`Editor/Restart/Launch.lean`). `mode` strips them
  (`Restart.Launch.strip`) before it dispatches on the rest, and hands them
  to the modes that act on them as a `Restart.Launch`. The launcher's own
  options share no name with these or with any mode's.
- `editor demo` alone is the demonstration: it calls the Rust library and
  prints what comes back.
- `editor --version` alone says the version, the build ID and the commit
  of the running build (`Editor/Version.lean`). `--version` with anything
  else is the window mode's, which refuses it as an option it does not
  know.
- `editor --probe` alone is the probe a restart runs before it hands the
  session over (`Editor/Restore/Restart.lean`): it prints `probe: ok` once
  `main` is reached, so every module initialiser has run, then how it was
  launched and the main bundle it sees. `--probe` with anything else is
  the window mode's, as `--version` is.
- `editor headless …` is the headless mode, handed the rest of the command
  line (`Editor/Headless.lean`).
- `editor window-check …` is the keyboard check, handed its options
  (`Editor/WindowCheck.lean`).
- Any other command line is the window mode's (`Editor/Window.lean`),
  handed whole. An empty one is the window mode on its one empty buffer,
  which is how Finder starts the app. So a file called `demo`, `headless` or
  `window-check` is opened as `./demo`, `./headless` or `./window-check`,
  and `editor demo x` is the window mode's, which refuses two files.

`Mode.needsScheme` says which modes run an input scheme: the headless
mode, the window mode and the probe. `Editor.Main.run` refuses those when
its package set supplies no scheme (`Editor/InputScheme.lean`, "The scheme
a package supplies"), with the line `Executable.schemeRefusal?` gives
(`Editor/Executable/Refusal.lean`).

It imports only the launch flags' leaf module, and `Editor` does not import
it, so it adds nothing to what config is elaborated on.
-/

namespace Editor.Executable

/-- What the executable runs. -/
inductive Mode where
  /-- The demonstration. -/
  | demo
  /-- The version, the build ID and the commit. -/
  | version
  /-- The probe: `probe: ok`, the launcher and the main bundle. -/
  | probe (launch : Restart.Launch)
  /-- The headless mode, with the command line after `headless`. -/
  | headless (launch : Restart.Launch) (arguments : List String)
  /-- The keyboard check, with the options after `window-check`. -/
  | windowCheck (options : List String)
  /-- The window mode, with the whole command line. -/
  | window (launch : Restart.Launch) (arguments : List String)
  deriving DecidableEq, Repr

/-- The mode the command line `arguments` selects, its launch flags
stripped first. -/
def mode (arguments : List String) : Mode :=
  let (launch, rest) := Restart.Launch.strip arguments
  match rest with
  | ["demo"] => .demo
  | ["--version"] => .version
  | ["--probe"] => .probe launch
  | "headless" :: rest => .headless launch rest
  | "window-check" :: options => .windowCheck options
  | arguments => .window launch arguments

/-- Whether the mode runs an input scheme, so that the executable refuses
it when its package set supplies none (`Editor.Main.run`): the headless
mode and the window mode run the loop, and the probe says whether a start
would succeed. The demonstration, the version and the keyboard check run no
scheme. -/
def Mode.needsScheme : Mode → Bool
  | .headless .. | .window .. | .probe .. => true
  | .demo | .version | .windowCheck .. => false

end Editor.Executable
