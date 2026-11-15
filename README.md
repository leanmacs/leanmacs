# leanmacs

An Emacs-style editor written in Lean 4. Lean owns the process and is the
editor: its state, the command loop, commands, modes, keymaps and config. A
Rust library, linked into the Lean executable, provides text storage, layout,
rendering, the window, and process and terminal management.

Milestone 1 is built: `editor <file>` opens a file in a window, drawn with
wgpu in the system's monospace font, and edits it with Vim's keys (evil:
motions, operators, counts, registers, undo and redo, `.`), saves it with
`:w`, opens another with `:e`, quits with `:q`, and loads config written in
Lean from a directory at start and again on `:reload`, saying a broken
config's first error in the bottom row while the old config keeps running.
It does not yet reload a file another program changed, take the mouse,
draw a pending key prefix or an input method's composition, or refuse to
close with unsaved changes.

- [`docs/design/`](docs/design/README.md) says what is being built and why.
- [`docs/dev-practices/`](docs/dev-practices/README.md) says how to test it
  and what must pass before a change lands.
- [`AGENTS.md`](AGENTS.md) holds the working rules.

## Building

The build runs on macOS and on Linux. Windows has not been attempted.

### Prerequisites

- [mise](https://mise.jdx.dev), which installs the tools `mise.toml` pins
  (Rust, cargo-deny, hk, pkl, clang-format) and runs every task. Run
  `mise install` once in the checkout.
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
mise run lean
```

This builds everything: the Lean package, the Rust library and the C glue.
Use it in place of a bare `lake build`
([why](docs/dev-practices/building.md)). The editor is then
`lean/.lake/build/bin/editor`.

```sh
mise run edit -- <file>
```

This opens `<file>`, relative to the directory you ran it from, in the
editor's window, with the pinned Lean toolchain given so that config can
load. Options go before the file:

- `--config <dir>`: the config directory, one `.lean` chunk per file, read
  in byte order of the names. By default `leanmacs` under
  `$XDG_CONFIG_HOME`, or `~/.config/leanmacs`; a default directory that
  does not exist loads nothing. `:reload` loads it again.
- `--no-ime`: no input method composes.
- `--report`, `--present-mode <mode>` and `--frame-latency <n>`: print the
  frame journal's figures when the window closes, and ask for another
  present mode for this run, to measure it
  ([on-demand-checks.md](docs/dev-practices/on-demand-checks.md)).

`lean/.lake/build/bin/editor <file>` runs it directly; it then loads no
config unless given `--sysroot <dir>`, the Lean toolchain's directory
(`lean --print-prefix`).

```sh
mise run ci
```

This runs every check a change must pass
([`docs/dev-practices/the-gate.md`](docs/dev-practices/the-gate.md)).

## Licence

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
