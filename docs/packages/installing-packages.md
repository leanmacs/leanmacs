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
which requires the package set the editor was built from:

```toml
name = "config"

[[require]]
name = "default-set"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set"

[[lean_lib]]
name = "Config"
globs = ["Config.+"]
```

`path` is where the editor's own set is: in the app, its
`Contents/Resources/lean/set`; built from a checkout, the checkout's
`packages/`. The editor never rewrites a lakefile that is there.

The default set requires the core, `editor-core`, and the default packages:

- [`shipped-themes`](../../packages/shipped-themes/README.md): the themes
  `solarized-dark`, `solarized-light` and `fairy-floss`.
- [`compile`](../../packages/compile/README.md): `:compile`, `:next-error`
  and the rest of the compile mode, with modes for cargo, lake and mise.

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
the Reservoir registry. Each adds a `[[require]]` table after the last one
in `lakefile.toml`, then reloads. The same by hand:

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
of every git and Reservoir package, moves the pin and builds.
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
with a table for each of the set's own requires but `compile`:

```toml
name = "config"

[[require]]
name = "editor-core"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/lean"

[[require]]
name = "shipped-themes"
path = "/Applications/Leanmacs.app/Contents/Resources/lean/set/shipped-themes"

[[lean_lib]]
name = "Config"
globs = ["Config.+"]
```

The tables of packages you added stay as they were. `editor-core` cannot
be removed, and a name the lakefile does not require is refused. By hand,
make the same edit and `:reload`.

## Editing the lakefile by hand

- **The commands edit only `[[require]]` tables** of a `lakefile.toml`, as
  text, and leave the rest of the file, comments included, as it is. A
  lakefile whose requires are not each a `[[require]]` table is refused:
  edit it by hand.
- **A command refuses a lakefile that changed since the last reload**:
  `:reload` and try again.
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
- **Cargo**, for a package that holds a Rust crate: install it from
  <https://rustup.rs>.
- **A C header, framework or system library**, for a package with C code:
  install the Xcode command line tools (`xcode-select --install`), or use
  the package's prebuilt binary.

A new editor that is built but does not start, because its link is bad or a
package's `initialize` throws, is caught before the restart: nothing is
published and the running editor keeps running.

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
  ships no macOS SDK, no C headers and no Cargo. A package with C that
  includes only `lean/lean.h` builds from the app; one with other C needs
  the Xcode command line tools, or a prebuilt binary its lakefile fetches. A
  package with a Rust crate builds only from a checkout of the editor, with
  your own Cargo, and only when the crate is in the editor's repository;
  one from elsewhere is refused for now.

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
