# leanmacs

[![Licence: GPL-3.0-or-later](https://img.shields.io/badge/licence-GPL--3.0--or--later-blue)](LICENSE)

A text editor whose config and extensions are written in Lean.

leanmacs is an Emacs-style editor with Vim's keys. Lean owns the process
and is the editor: its state, the command loop, commands, modes, keymaps
and config. A Rust library, linked into the Lean executable, provides text
storage, layout, rendering, the window and processes.

## What it does

- Opens files in a window drawn with wgpu in the system's monospace font,
  and edits them with Vim's keys: motions, operators, counts, registers,
  visual selections, undo and redo, and `.`.
- Several buffers (`:b`, `:ls`, `:bd`), windows in tiling layouts
  (master-and-stack, monocle, manual splits) under Vim's `C-w` keys, and
  tabs.
- Syntax highlighting with tree-sitter for Rust, JSON, Markdown, TOML and
  Lean.
- Themes: the default, Solarized dark and light, Fairy Floss, and your own.
- `:!` to run a shell command, and `:compile` with `:next-error`.
- Config written in Lean, loaded at start and again on `:reload`. A config
  that fails to elaborate is rejected, its first error is shown in the
  bottom row, and the old config keeps running.

### Limitations

- Tree-sitter grammars are compiled in. Only the five languages above are
  highlighted, and adding a grammar means rebuilding the editor.
- The mouse does nothing.
- The pending key prefix and an input method's composition are not drawn.
- A rejected reload shows only its first error in the window; the full
  report goes to stderr.
- A config file has no `import` line: it sees only what the editor's
  `Editor` module imports, not `Std` or `Lean`.
- The download is for macOS on Apple silicon only. On Linux, build it from
  source; Windows has not been attempted.
- The app is ad-hoc signed and not notarized, so macOS blocks its first
  launch (see [Download](#download)).
- There is only the rolling nightly, with no versioned releases, and the
  app does not update itself: download it again to update.

## Download

The nightly is a rolling build of `main`: each push to `main` that passes
the gate replaces it. It needs macOS 26.0 or later, on Apple silicon.

- Download page: <https://leanmacs.github.io/leanmacs/>
- The newest image, at a permanent link:
  <https://github.com/leanmacs/leanmacs/releases/download/nightly/Leanmacs.dmg>

Open the image and drag Leanmacs.app onto Applications.

The app is ad-hoc signed and not notarized, so macOS blocks it the first
time. Since macOS 15, Control-click > Open no longer gets past this.
Instead:

1. Open Leanmacs once. macOS says it cannot check it; click Done.
2. Open System Settings > Privacy & Security, scroll down, and click
   "Open Anyway" beside the message about Leanmacs.
3. Open Leanmacs again and confirm.

If that does not work, remove the quarantine flag in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Leanmacs.app
```

To see which build you have:

```sh
/Applications/Leanmacs.app/Contents/MacOS/editor --version
```

It prints the version, the build ID (the commit's time, UTC,
YYYYMMDDHHMMSS) and the commit.

## Config

Config is Lean source in a directory: `~/.config/leanmacs`, or
`$XDG_CONFIG_HOME/leanmacs` when that variable is set and not empty. Each
`.lean` file directly in it is one chunk, and the chunks are elaborated in
the byte order of their names (`10-keys.lean` before `20-setup.lean`).
One of them defines `setup : SetupM Unit`, which registers commands, key
bindings and options; the editor runs it once the chunks elaborate. The
config is loaded at start and again on `:reload`, with no restart. A
default directory that does not exist loads nothing.

An example, as `~/.config/leanmacs/10-init.lean`:

```lean
-- A command of your own: it says hello in the bottom row.
def hello : EditorM Unit :=
  message "hello from my config"

def setup : SetupM Unit := do
  useTheme "solarized-dark"         -- a shipped theme
  framePadding 12                   -- points around each window's text
  autoReload                        -- follow files changed on disk
  command "say-hello" hello
  bindKey "C-c h" "say-hello"       -- Control-c, then h
  exCommand "hello" "say-hello"     -- :hello
```

Save it, then start the editor or type `:reload`, and `C-c h` or `:hello`
says hello. If it fails to elaborate, the bottom row shows the first error
and the old config stays. Everything `setup` can register is in
[`lean/Editor/Setup.lean`](lean/Editor/Setup.lean), and each config under
[`tests/headless/`](tests/headless/) is a small working example.

From source, `mise run edit` loads the same directory, or another given
with `--config <dir>`. The app reads it too. Started from Finder it gets launchd's
environment, not your shell's, so an `XDG_CONFIG_HOME` exported in the
shell does not reach it (`launchctl setenv` does).

## Building

To run leanmacs from source. The build runs on macOS and on Linux; the app
bundle builds on macOS on arm64 only. Windows has not been attempted.

### Prerequisites

- [mise](https://mise.jdx.dev), which installs the tools `mise.toml` pins
  (Rust, cargo-deny, hk, pkl, clang-format, actionlint, zizmor and yq, and
  gitleaks and OpenTofu, which only `mise run secrets-scan` and the
  `infra-*` tasks use) and runs every task.
- `uv` or `pipx`. mise uses one of them to install clang-format.
- Lean, at exactly the version in `lean/lean-toolchain`, with `lean` and
  `lake` on the `PATH`. `mise install` does not provide it from
  `mise.toml`. Either install [elan](https://github.com/leanprover/elan),
  which reads that file, or use mise's `lean` plugin with
  `idiomatic_version_file_enable_tools = ["lean"]` in your global mise
  config, so that mise reads the same file (`mise.toml`'s comment says
  so).
- A system C compiler at `/usr/bin/cc`. On macOS, the Xcode command line
  tools. On Linux, gcc with GNU ld and the C library's headers (Debian's
  `build-essential`).
- On Linux, also `git`, `curl`, `zstd` and `pkg-config`, and, to open a
  window, the X11 libraries the window library loads at run time.
  `tools/linux/Dockerfile` has the whole list, for Debian 13.
- Network access for the first build.

### Build and run

```sh
mise install            # once, in the checkout
mise run lean           # builds the Lean package, the Rust library and the C glue
mise run edit -- [<file>]
```

Use `mise run lean` in place of a bare `lake build`
([why](docs/dev-practices/building.md)). The editor is then
`lean/.lake/build/bin/editor`.

`mise run edit` builds first, then opens `<file>`, relative to the
directory you ran it from, in the editor's window, or an empty buffer when
no file is given. It hands the editor the pinned Lean toolchain, so config
loads. Options go before the file:

- `--config <dir>`: the config directory, in place of the default
  ([Config](#config)).
- `--no-ime`: no input method composes.
- `--report`, `--present-mode <mode>` and `--frame-latency <n>`: print the
  frame journal's figures when the window closes, and ask for another
  present mode for this run, to measure it
  ([on-demand-checks.md](docs/dev-practices/on-demand-checks.md)).

`lean/.lake/build/bin/editor <file>` runs it directly; it then loads no
config unless given `--sysroot <dir>`, the Lean toolchain's directory
(`lean --print-prefix`).

### The macOS app

On macOS on arm64:

```sh
mise run app          # builds lean/.lake/build/Leanmacs.app, ad-hoc signed
mise run app-check    # builds it and checks the bundle
mise run install      # does both, then replaces /Applications/Leanmacs.app
mise run dmg          # builds it and packs dist/Leanmacs-<build-id>.dmg
mise run dmg-check    # checks that image
```

`mise run install` keeps no backup of the app it replaces. When
`~/.config/leanmacs` does not exist it installs a small config,
[`tests/headless/finder-session/config`](tests/headless/finder-session/config/10-finder-session.lean),
whose `C-c h` shows `finder-session: config loaded`.

The app holds its own Lean toolchain modules
([building.md](docs/dev-practices/building.md), "The app bundle"). Finder
offers it under Open With for plain text and source code, and it opens a
file dropped on its Dock icon. Its signature is ad-hoc, for this machine
only.

## Contributing

- [`AGENTS.md`](AGENTS.md) holds the working rules: test-first, ports and
  adapters, conventional commits.
- `mise run ci` runs the gate, every check a change must pass
  ([`the-gate.md`](docs/dev-practices/the-gate.md)).
- [`docs/dev-practices/`](docs/dev-practices/README.md) says how to build,
  test and check it, and how CI and the nightly work.
- [`docs/design/`](docs/design/README.md) says what is being built and why.
- [`docs/dev-practices/publishing.md`](docs/dev-practices/publishing.md)
  says what is published and how the repository's settings are kept.

## Licence

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
