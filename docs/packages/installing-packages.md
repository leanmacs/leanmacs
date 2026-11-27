# Installing packages

The packages your editor holds are named by one file, your config
directory's `lakefile.toml`. This guide is how to add a package to it, update
one, and remove one, the default packages included, with the editor's
commands or by editing that file. How the editor builds a set is in
[packages.md](../design/packages.md), ["User package
sets"](../design/packages.md#user-package-sets). To write a package, see
[writing-a-package.md](writing-a-package.md).

## Your package set is your config's `lakefile.toml`

Your config directory (`~/.config/leanmacs`, or `$XDG_CONFIG_HOME/leanmacs`)
is a Lake package. When it has no lakefile, the editor writes this one,
which requires the package set the editor was built from, then the
editor's own core:

```toml
name = "config"

[[require]]
name = "default-set"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set"

[[require]]
name = "editor-core"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/lean"

[[lean_lib]]
name = "Config"
globs = ["Config.+"]
```

The first `path` is where the editor's own set is: in the app, its
`Contents/Resources/lean/set`; built from a checkout, the checkout's
`packages/`. The second is the core the editor is linked from: in the app,
`Contents/Resources/lean/lean`; built from a checkout, its `lean/`. The
core comes last on purpose: Lake takes the last require of a name over any
a package makes, so every package builds against the editor's own core,
even one that names the core from git, and no core is downloaded. The
editor never rewrites a lakefile that is there, but each package command
writes the core's require back as the last one (see "Editing the lakefile
by hand").

The default set requires the core, `editor-core`, and the default
packages. The core itself registers no package: every feature of the
editor is one of these, and each can be removed.

- [`ex`](../../packages/ex/README.md): the ex command line, `quit`,
  `save-and-quit` and `reload-config`, and the ex names `w`, `e`, `q`,
  `wq`, `reload`, `b`, `ls`, `bd` and their kin. It requires the interface
  packages `ex-api`, `buffers-api` and `shell-api`. Without it there is no
  ex line, so no `:package-…` command can be typed either, and `quit` is
  no command; the window's close button still quits.
- [`frame-commands`](../../packages/frame-commands/README.md):
  `toggle-fullscreen` and `minimise-window`, with `C-s-f`, `s-m` and
  `s-q`. It requires `frame-commands-api`.
- [`menu`](../../packages/menu/README.md): the menu bar that ships and the
  keys of its File and Edit items. It requires `evil-api` and
  `frame-commands-api`. Without it there is no menu bar unless your config
  defines one.
- [`window-commands`](../../packages/window-commands/README.md) and
  [`tab-commands`](../../packages/tab-commands/README.md): the commands
  that split, close, focus and arrange windows, and that open, close and
  select tabs. Each requires its interface package, `window-commands-api`
  and `tab-commands-api`.
- [`restore`](../../packages/restore/README.md): session restore's
  registrations. The work is the editor's own, but it runs only where
  this package registers it: without it nothing is journalled, no session
  is restored, `restart` is no command, and a package-set build ends
  without a restart.
- [`package-set`](../../packages/package-set/README.md): `:package-install`,
  `:package-remove` and `:package-update`, and the registration of the
  build that follows a changed lakefile. Without it those three commands
  are gone and a changed lakefile is not built: edit the lakefile by hand
  to put it back, and restart.
- [`evil`](../../packages/evil/README.md): the Vim scheme and evil, Vim's
  states, motions, operators and the rest of its commands. It supplies the
  editor's input scheme, and requires the interface packages `evil-api`,
  `minibuffer-api`, `at-point-api`, `window-commands-api`,
  `tab-commands-api`, `ex-api`, `buffers-api` and `shell-api`. Without it, and with no other
  package that supplies a scheme, the editor would refuse to start
  ("Removing, default packages included", below).
- [`themes`](../../packages/themes/README.md): `load-theme` and the theme
  `default`. It requires its interface package, `themes-api`. Without it
  the theme in force is still the built-in one, named `default`, and config
  still defines and names themes.
- [`files`](../../packages/files/README.md): the file commands,
  `open-file`, `save-buffer`, `edit-file`, `reload-buffer` and
  `auto-reload-mode`. Without it no file opens and none is saved.
- [`buffers`](../../packages/buffers/README.md): `switch-buffer`,
  `list-buffers` and `close-buffer` (`:b`, `:ls`, `:bd`).
- [`workspace`](../../packages/workspace/README.md): a file's workspace,
  `find-file-in-workspace` and `find-file-in-project`. It requires the
  interface packages `project-api` and `vc-api`. Without it no buffer has a
  workspace.
- [`project-search`](../../packages/project-search/README.md):
  `project-search` and `project-search-symbol` (`SPC /`, `SPC *`). It
  requires its interface package, `project-search-api`.
- [`working-set`](../../packages/working-set/README.md): the working sets,
  `working-set-add` and `working-set-open` (`SPC k a`, `SPC k o`). It
  requires its interface package, `working-set-api`, and `vc-api`.
- [`shell`](../../packages/shell/README.md): `:!` and `:<range>!`, and
  `keyboard-quit`.
- [`version-control`](../../packages/version-control/README.md): git's
  status, commit, review, log and blame buffers and the gutter, two
  packages, `version-control` and `version-control-gutter`. It requires
  `project-api` and `vc-api`.
- [`completion`](../../packages/completion/README.md): the completion
  styles `fuzzy`, the default, `orderless` and `path`, and the candidate
  list's display `minibuffer`. It requires its interface package,
  `completion-api`. Without it every prompt is matched by the core's own
  style and its list drawn plain.
- [`mode-line`](../../packages/mode-line/README.md): the segments of the
  mode line that ship, the Vim state's badge, the buffer's name, line:col
  and the rest.
- [`minibuffer`](../../packages/minibuffer/README.md): the commands that
  answer a prompt, `minibuffer-accept` (`RET`), `minibuffer-cancel`
  (`<Escape>`) and the rest, and the minibuffer's mode. It requires its
  interface package, `minibuffer-api`. Without it a prompt opens and
  nothing answers it, and no candidate that answers later arrives.
- [`shipped-themes`](../../packages/shipped-themes/README.md): the themes
  `solarized-dark`, `solarized-light` and `fairy-floss`.
- [`execute-command`](../../packages/execute-command/README.md): the
  command prompt, `execute-command` (`SPC :` in the default config). It
  requires its interface package, `execute-command-api`, which registers
  nothing.
- [`binding-search`](../../packages/binding-search/README.md): the binding
  search, `search-bindings` (`SPC ?` in the default config). It requires
  its interface package, `binding-search-api`.
- [`compile`](../../packages/compile/README.md): `:compile`, `:next-error`
  and the rest of the compile mode, with modes for cargo, lake and mise.
- [`at-point`](../../packages/at-point/README.md): completion at point in
  insert state, `C-SPC`, `C-n` and the rest, and the source `words`. It
  requires its interface package, `at-point-api`. Without it `RET`, `TAB`
  and `C-g` in insert state do nothing, since the Vim scheme binds them to
  its commands.
- [`languages`](../../packages/languages/README.md): the languages that
  ship, `rust`, `json`, `markdown`, `toml` and `lean`, and the `code` mode
  files of them open in.

Every `[[require]]` you add is a package of your editor. When a reload
finds the requires, or the revisions `lake-manifest.json` pins, differ from
those the running editor was built from, it builds a new editor.

## Installing

```
:package-install <name> <path>
:package-install <name> <git url> [<rev>]
:package-install <scope>/<name> [<version>]
```

The first form requires a package in a directory on this machine, the
second a git repository, at `<rev>` if given, and the third a package from
the Reservoir registry. Each adds a `[[require]]` table after the last
package's in `lakefile.toml`, ahead of the core's, then reloads. The same by
hand, before the `editor-core` table:

```toml
[[require]]
name = "word-count"
path = "/Users/me/src/word-count"
```

or, for git, `git = "<url>"` and an optional `rev = "<rev>"`; or, for
Reservoir, `scope = "<scope>"` and an optional `version = "<version>"`. Save
the file and `:reload`.

What you see:

- **The build runs in the background**, its output in the buffer
  `*package-build*`, and you keep editing.
- **When it is built, the editor restarts into the new editor** with your
  session: the buffers, their unsaved text, the windows and the tabs.
- **Until then, config that imports the package is refused.** A config file
  that imports a module of a package the lakefile requires but the running
  editor does not hold gets a diagnostic saying the package set needs a
  rebuild, and the build still starts.

## Updating

```
:package-update                  every git and Reservoir package
:package-update <name>           one package
:package-update <name> <rev>     one git package, to that revision
```

The lakefile names what is required. `lake-manifest.json`, which the build
writes beside it, pins the revision of each git package. `:package-update`
with no rev edits nothing: it fetches the newest revision of the package, or
of every git and Reservoir package, moves the pin and builds. On a lakefile
an older editor wrote, without the core's require, it writes that require
first and updates nothing: run it again.
`:package-update <name> <rev>` writes `rev = "<rev>"` into that package's
table and builds at that revision.

By hand: edit a git require's `rev` and `:reload`. A `rev` the manifest does
not pin is fetched, pinned and built.

## Removing, default packages included

```
:package-remove <name>
```

It takes the package's `[[require]]` table out and reloads. A default
package is removed the same way. Your lakefile requires the default set, not
`compile`, so `:package-remove compile` replaces the default set's table
with a table for each of the set's own requires but `compile` and the core,
which the lakefile already requires:

```toml
name = "config"

[[require]]
name = "ex"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/ex"

[[require]]
name = "frame-commands"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/frame-commands"

[[require]]
name = "menu"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/menu"

[[require]]
name = "window-commands"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/window-commands"

[[require]]
name = "tab-commands"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/tab-commands"

[[require]]
name = "restore"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/restore"

[[require]]
name = "package-set"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/package-set"

[[require]]
name = "evil"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/evil"

[[require]]
name = "themes"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/themes"

[[require]]
name = "files"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/files"

[[require]]
name = "buffers"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/buffers"

[[require]]
name = "workspace"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/workspace"

[[require]]
name = "project-search"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/project-search"

[[require]]
name = "working-set"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/working-set"

[[require]]
name = "shell"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/shell"

[[require]]
name = "version-control"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/version-control"

[[require]]
name = "completion"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/completion"

[[require]]
name = "mode-line"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/mode-line"

[[require]]
name = "minibuffer"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/minibuffer"

[[require]]
name = "shipped-themes"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/shipped-themes"

[[require]]
name = "execute-command"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/execute-command"

[[require]]
name = "binding-search"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/binding-search"

[[require]]
name = "at-point"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/at-point"

[[require]]
name = "languages"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/languages"

[[require]]
name = "editor-core"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/lean"

[[lean_lib]]
name = "Config"
globs = ["Config.+"]
```

The tables of packages you added stay as they were. `editor-core` cannot
be removed, and a name the lakefile does not require is refused. By hand,
make the same edit and `:reload`.

**Removing `evil`** leaves a set with no input scheme, unless another
package of yours supplies one. An editor of such a set refuses to start:
it prints `editor: no input scheme is installed: no package of this
editor's package set supplies one` and exits 1. So the build of the set
fails: the new editor links, but the build probes it before it publishes
it, and the probe is refused the same way. Nothing is published, there is
no restart, and the editor you are in keeps running and says why:

```
packages: the new editor did not start: it exited with status 1; editor: no input scheme is installed: no package of this editor's package set supplies one; this editor keeps running
```

Install a package that supplies a scheme, or put `evil`'s table back, and
`:reload`.

## Editing the lakefile by hand

- **The commands edit only `[[require]]` tables** of a `lakefile.toml`, as
  text, and leave the rest of the file, comments included, as it is. A
  lakefile whose requires are not each a `[[require]]` table is refused:
  edit it by hand.
- **A command refuses a lakefile that changed since the last reload**:
  `:reload` and try again.
- **Every command writes the core's require last.** `:package-install`,
  `:package-remove` and `:package-update <name> <rev>` take any
  `editor-core` table out, whatever it says, and add `editor-core` by the
  running editor's core directory after the last require; `:package-update`
  with no rev writes it when it is not there. So a lakefile an
  older editor wrote, which requires the default set alone, or one you
  edited, is repaired by the next command. A `:reload` never rewrites it.
  So `editor-core` itself cannot be installed, given a rev or removed.
- **A `lakefile.lean` is never edited.** The commands say they edit
  `lakefile.toml` only. Any change to a `lakefile.lean` starts a build,
  since it is a program and is not read.
- **The build writes into the config directory**: `.lake/`, where git
  packages are cloned and built, and `lake-manifest.json`. If your config
  directory is a git repository, ignore `.lake/` and commit the manifest,
  which holds the pins.

## When a build fails

The errors stay in `*package-build*`, whose last line is `Package build
failed: <how>`, and the echo area says `packages: <how>; this editor keeps
running`. The running editor keeps running, nothing is published, and the
editor the launcher starts next time is the one it started before. Fix the
cause and `:reload` to try again.

A failure for want of a tool says which tool and how to get it:

- **git**, for a git or Reservoir package: install it with
  `xcode-select --install` on macOS, or from <https://git-scm.com>.
- **A C header, framework or system library**, for a package with C code:
  install the Xcode command line tools (`xcode-select --install`), or use
  the package's prebuilt binary.
- **The tool a package's native library is built with** (Cargo, zig, a C
  compiler), for a package whose library is not already built: the build
  stops with `<tool> is required to build <package>'s library, and none
  works here (<how>): …`. Install the tool (Cargo from <https://rustup.rs>), or
  use the package's prebuilt library, as its documentation says. A package
  whose library is already built needs no tool of yours at all.
- **A package that still declares an `editorRustCrate` target** is refused:
  the editor no longer compiles a package's Rust into its own archive, and
  the message names the package and says to ship its Rust as a library of
  its own. Ask its author for a version that does.

A new editor that is built but does not start, because its link is bad or a
package's `initialize` throws, is caught before the restart: nothing is
published and the running editor keeps running.

A package's library that the new editor refuses to load is caught the same
way. The failure line reads `the new editor did not start: it exited with
status 1; uncaught exception: <package>: …`, naming the package and its
library, and the author's guide lists each message and what to do
([writing-a-package.md](writing-a-package.md), "A native library", "When a
library is refused").

**A set that would build another core** is refused before anything is
linked. If the lakefile does not require `editor-core` last, by the running
editor's core, Lake may take a package's own require of the core instead,
clone it and build it from source: an editor that is not the one you run.
The build stops after Lake resolves the set, and says so:

```
packages: the package set resolves editor-core to git <url> at <rev>, not this editor's core <core>; require it at the root of <config>/lakefile.toml with path = "<core>", as its last require, after every other (:package-install and :package-remove write it), then :reload; this editor keeps running
```

To fix it, run any package command (`:package-remove` of a package and
`:package-install` it again, say), which writes the core's require back as
the last one, or add it by hand as the message says, and `:reload`.

## When the editor updates

Your packages were built against the old editor's core, so the first launch
after an update starts the editor the app ships, with the default packages
only. Its first reload builds your set against the new core and restarts
into it. If that build fails, the shipped editor keeps running with the
errors in `*package-build*`.

## What you need installed

- **Nothing more for path packages and the default packages.** The app
  ships the Lean toolchain, and a set of pure-Lean packages builds from it
  alone.
- **The system `git` for git and Reservoir packages**: `xcode-select
  --install` on macOS, or <https://git-scm.com>.
- **For a package with native code, what its documentation says.** The app
  ships no macOS SDK, no C headers and no Cargo. A package's native code is
  a library loaded when the editor starts. One the package ships already
  built needs no Cargo or other compiler of yours at `:reload`. A package
  whose library its lakefile builds runs your own tooling (Cargo, zig, a C
  compiler) at `:reload`, which is the fallback, and its documentation
  says which. A package's C glue that includes only `lean/lean.h` builds
  from the app; other C needs the Xcode command line tools.
- **The agents packages** (`agents-api` and `acp`) are opt-in and come from
  a checkout of the editor: `mise run install -- --agents` builds acp's
  library with your Cargo, there, and adds both to your config, whose
  `:reload` then needs no Cargo. Run it again after updating the
  checkout.

## Where builds live

Built editors are under `~/.local/share/leanmacs/editors` (or
`$XDG_DATA_HOME/leanmacs/editors`), one directory per core and a numbered
directory per build. At most two builds are kept per core, plus the running
one when it is older. The launcher starts the newest, falling back to the
one before, then to the editor the app ships. A build of a set holds a copy
of the executable and of every module it links: the test fixture set's
measured about 420 MB ([packages.md](../design/packages.md), "The install:
a set's editor in one directory").

## Trust

Packages run with your authority, as config does: a package's code, its
`initialize` included, can do anything you can. Its `initialize` runs
whenever an editor built with it starts, the check the build runs on the new
editor before the restart included. Install only packages you would run as
your own code.
