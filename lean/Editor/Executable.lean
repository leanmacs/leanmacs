/-!
# The executable's top-level dispatch

Which mode the editor executable runs, given its command line (`mode`). It
is pure, so `model-test` pins it (`ModelTest.executableModeChecks`), and
`Editor.Main.run` (`Editor/Main.lean`) acts on what it selects.

- `editor demo` alone is the demonstration: it calls the Rust library and
  prints what comes back.
- `editor --version` alone says the version, the build ID and the commit
  of the running build (`Editor/Version.lean`). `--version` with anything
  else is the window mode's, which refuses it as an option it does not
  know.
- `editor headless …` is the headless mode, handed the rest of the command
  line (`Editor/Headless.lean`).
- `editor window-check …` is the keyboard check, handed its options
  (`Editor/WindowCheck.lean`).
- Any other command line is the window mode's (`Editor/Window.lean`),
  handed whole. An empty one is the window mode on its one empty buffer,
  which is how Finder starts the app. So a file called `demo`, `headless` or
  `window-check` is opened as `./demo`, `./headless` or `./window-check`,
  and `editor demo x` is the window mode's, which refuses two files.

It imports nothing, and `Editor` does not import it, so it adds nothing to
what config is elaborated on.
-/

namespace Editor.Executable

/-- What the executable runs. -/
inductive Mode where
  /-- The demonstration. -/
  | demo
  /-- The version, the build ID and the commit. -/
  | version
  /-- The headless mode, with the command line after `headless`. -/
  | headless (arguments : List String)
  /-- The keyboard check, with the options after `window-check`. -/
  | windowCheck (options : List String)
  /-- The window mode, with the whole command line. -/
  | window (arguments : List String)
  deriving DecidableEq, Repr

/-- The mode the command line `arguments` selects. -/
def mode : List String → Mode
  | ["demo"] => .demo
  | ["--version"] => .version
  | "headless" :: rest => .headless rest
  | "window-check" :: options => .windowCheck options
  | arguments => .window arguments

end Editor.Executable
