# leanmacs

An Emacs-style editor written in Lean 4. Lean owns the process and is the
editor: its state, the command loop, commands, modes, keymaps and config. A
Rust library, linked into the Lean executable, provides text storage, layout,
rendering, the window, and process and terminal management.

The editor does nothing useful yet: the executable shows that the build
works.

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
  `lake` on the `PATH`. `mise install` does not provide it;
  [elan](https://github.com/leanprover/elan) reads that file and does.
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
mise run ci
```

This runs every check a change must pass
([`docs/dev-practices/the-gate.md`](docs/dev-practices/the-gate.md)).

## Licence

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
