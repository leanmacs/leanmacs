# Building: what the build does and why

The prerequisites and the one command are in the top-level
[`README.md`](../../README.md). This is what that command does.

```sh
mise run lean
```

This one command builds everything. Lake compiles the Lean package, runs
`cargo build` for the Rust static library (`crates/editor-ffi`), compiles the
C glue (`lean/ffi/glue.c`) and links the executables. Every Lean linter is
on, and a warning fails the build.

The editor is `lean/.lake/build/bin/editor`. `editor demo` shows the
build works:

```console
$ lean/.lake/build/bin/editor demo
Rust says 2 + 3 = 5
Lean's main is on the process's main thread: false
The main-thread service is on the process's main thread: true
A command appended to a text held by Rust: héllo wörld
```

The last line is a command, `Editor.append`, run against the Rust library.
The model tests run the same source against a pure Lean model. With no
arguments at all the editor opens its window on an empty buffer, as Finder
starts the app (`lean/Editor/Executable.lean` is the dispatch).

The executable is about 206 MB on macOS: it can elaborate config, so
Lean's elaborator is linked into it, and since milestone 1 the static
library holds the wgpu renderer, Parley and arboard too, which took it
from about 184 MB. Every executable that links the library (`editor`,
`ffi-test`, `contract-test`, `config-test`) holds them. On macOS the link
names the frameworks they need beside the window's: Metal, QuartzCore and
CoreText (`lean/lakefile.lean`, `linkArgs`); a framework missing shows as
`Undefined symbols for architecture arm64` from `mise run lean`. On Linux
the size was 265 MB before milestone 1 and has not been measured since.

### The headless mode

Lake relinks the executables only when the Rust archive's contents change,
so a second `mise run lean` rebuilds nothing.

`mise run lean` runs the model tests first (`mise run lean-test`;
[`the-gate.md`](the-gate.md)).
That is only so that two Lake builds never run in `lean/` at once: the tasks
that run Lake form one chain.

Use `mise run lean`, not a bare `lake build`. On both platforms the
executables have to be compiled and linked by the system compiler, and the
task sets `LEAN_CC=/usr/bin/cc` to say so: the clang bundled with Lean has no
`pthread.h` for the glue, on macOS or on Linux, and on macOS its linker
cannot link the system frameworks the window needs. Do not export `LEAN_CC`
in your shell. lean-fmt has to build with Lean's bundled compiler, and on
macOS under `/usr/bin/cc` its link fails with `library 'gmp' not found`.

The executables also do not start at Lean's `main`. Lean runs `main` on a
thread it creates, never on the process's main thread, and macOS only lets a
window event loop run there. So `editor_entry` in the glue runs in its place.
It keeps the real main thread for the Rust library and runs Lean's `main` on
a second thread with a large stack. On macOS the link names it as the entry
point (`-Wl,-e,_editor_entry`). On Linux that would skip the C library's
start-up, so the link renames instead (`-Wl,--wrap=main`): the start-up code
calls the glue's `__wrap_main`, and Lean's `main` is reached as
`__real_main`.

## The app bundle

```sh
mise run app
```

This builds `lean/.lake/build/Leanmacs.app`, the editor as a macOS app
bundle, with Lake (`editorApp` in `lean/lakefile.lean`). It builds on
macOS on arm64 only; anywhere else the target fails with
`the app bundle builds only on macOS on arm64` and the toolchain's target.
It is not part of the gate, which never builds it.

What it holds:

```
Leanmacs.app/Contents/Info.plist
Leanmacs.app/Contents/MacOS/editor                         a copy of the editor executable
Leanmacs.app/Contents/Resources/Leanmacs.icns              the icon, made from lean/app/Leanmacs.png
Leanmacs.app/Contents/Resources/lean/toolchain/lib/lean/   the toolchain's modules
Leanmacs.app/Contents/Resources/lean/editor/               the editor's modules
```

The modules are the closure of `Editor`, the modules config is elaborated
on, each as its `.olean`, `.olean.server` and `.olean.private` files: the
layout and the file kinds `mise run bundle-test` stages
([`headless-mode.md`](headless-mode.md), "From an app bundle"), laid out by
the same `tools/stage-bundle.sh`. On 2026-11-15 that was 2,006 files,
382 MB, beside a 196 MB executable: 579 MB in all. `Info.plist` names the
bundle identifier `io.github.leanmacs.Leanmacs`, the executable `editor`,
the icon, `NSHighResolutionCapable`, `LSArchitecturePriority` arm64 and
`LSMinimumSystemVersion`, the lowest macOS the bundle has been run on:
26.0, which equals mise.toml's `MACOSX_DEPLOYMENT_TARGET`, so the
executable's `minos` is the same. CI's `mise run app-check` runs the
bundle's headless mode on the `macos-26` runner on every main build, and
the window was run by hand on 27.2; the owner chose 26.0 on 2026-11-17
([`ci.md`](ci.md), "Deployment target"). Its two document types (`CFBundleDocumentTypes`) are "Text"
(`public.text`, which every text type conforms to) at the rank `Alternate`,
offered under Finder's "Open With" but never chosen over another app, and
"Any file" (`public.data`) at the rank `None`, accepted on the Dock icon and
through "Open With > Other…" but never offered or chosen; the app is an
`Editor` of both. No rank is `Default` or `Owner`, and the plist declares
no types (no `UTImportedTypeDeclarations` or `UTExportedTypeDeclarations`). `LSApplicationCategoryType` is
`public.app-category.developer-tools`, and `NSHumanReadableCopyright` names
the licence, GPL-3.0-or-later.

Three keys say which build the bundle is, and `editor --version` prints
them (lean/Editor/Version.lean):

- `CFBundleShortVersionString` is the version, the one line of
  `lean/app/version`: 0.1.0, as every crate's `version` is. The line must
  be one to three dot-separated runs of digits, with or without a newline
  after it, and `editorApp` refuses anything else, a second line or
  whitespace among it, with an error naming the file.
- `CFBundleVersion` is the build ID, from `LEANMACS_BUILD_ID`: HEAD's
  committer time in UTC as `YYYYMMDDHHMMSS`, which `mise run build-id`
  prints. The committer time, not the author time: landing rebases, which
  resets it, so the ID goes up along `main`.
- `LeanmacsCommit` is the commit, HEAD's full SHA, from `LEANMACS_COMMIT`.

`mise run app` sets both variables with `leanmacs-release build-id` and
`commit` (`crates/editor-release-std`), which take each variable as it is
when it is set, as CI sets them from its run (the build ID from the
`build-id` job, the commit from `github.sha`), and read HEAD otherwise. A
bare `lake build editorApp` without them is refused, naming the variable;
`editorApp` checks only their shape (14 digits, 40 lowercase hex digits),
and the tool checks the build ID is a real time. A local build from a tree
with uncommitted changes is stamped with HEAD's commit all the same. The
plist is part of the bundle's trace, so a new commit rebuilds and re-signs
the bundle.

```sh
$ lean/.lake/build/Leanmacs.app/Contents/MacOS/editor --version
Leanmacs 0.1.0
build 20261117190046
commit 3d9490ca5c5244a972da004c20f1cf2b72ce29d9
```

Outside a bundle, as `lean/.lake/build/bin/editor`, `--version` says it is
a development build, with no version, build ID or commit.

The icon is made from `lean/app/Leanmacs.png`, a 1024×1024 PNG. Before
anything is built, `editorApp` reads its width, height and format with
`sips -g` and refuses any other size or format with an error naming the
file, since `sips -z` would stretch it into a blurred icon without a word.
`sips` scales it to the ten standard sizes (16, 32, 128, 256 and 512 points, at 1×
and 2×) in an iconset in the staging directory, and `iconutil` makes
`Leanmacs.icns` of them. The owner may replace the PNG with any 1024×1024
image that does not look the same turned a quarter (`mise run app-check`
turns it to show a new artwork rebuilds the icon).

Lake rebuilds the bundle only when an input changes: the executable, the
`Editor` library's modules, `config-test` (which lists the closure), the
stage script, the toolchain, the lakefile, the version file, the artwork,
or the build ID or commit.
A second `mise run app` with nothing changed copies and signs nothing, and
Lake prints no `Built editorApp` line. A rebuild starts from an empty
bundle, so it never keeps a module that is no longer imported. It assembles
and signs the bundle beside the old one, in `Leanmacs.app.staging`, and
renames it into place only then: Lake keeps the old trace when a build
fails, so a rebuild that fails or is interrupted leaves the old bundle,
never a half-built one that the old trace would take as up to date.

**It is signed again after assembly.** The linker signs the executable
ad-hoc, and that signature covers the Mach-O alone: with the bundle
assembled around it, `Info.plist` and `Contents/Resources` are not sealed,
and `codesign --verify --strict` refuses the bundle (`code has no resources
but signature indicates they must be present`). So the target clears the
bundle's extended attributes and signs the bundle as a whole with
`codesign --force --sign -`, as its last step: any write after that would
break the seal. The signature is ad-hoc, for this machine only. Developer
ID signing and notarization are a later task.

**The installed app reads config from `~/.config/leanmacs`**, or from
`$XDG_CONFIG_HOME/leanmacs` when that variable is set and not empty, as the
editor does anywhere: never from `~/Library/Application Support`. launchd
sets `HOME` for an app started from Finder, and normally not
`XDG_CONFIG_HOME`. The toolchain and the modules config is elaborated on
are the bundle's own, found from the executable's path.

`mise run install` installs the built bundle to `/Applications`, replacing
any installed one, and a config fixture to `~/.config/leanmacs` when no
config is there
([`on-demand-checks.md`](on-demand-checks.md), "Installing the app").

`mise run app-check` checks the built bundle
([`on-demand-checks.md`](on-demand-checks.md), "The app bundle, on demand").

### The disk image

```sh
mise run dmg
```

This builds the bundle (`mise run app`) and packs it into
`dist/Leanmacs-<build-id>.dmg`, a compressed HFS+ image whose volume,
"Leanmacs", holds exactly:

```
Leanmacs.app    the bundle, copied with ditto, so its signature holds
Applications    a link to /Applications, to drag the app onto
LICENSE         the repository's
README.txt      packaging/macos/README.txt: install, first launch, --version
```

`leanmacs-release dmg` (`crates/editor-release`, `dmg`) does it: it reads
the bundle's `CFBundleVersion` and refuses a bundle built for another build
than this one's ID, then stages the volume's root in `target/dmg/staging`,
packs it with `hdiutil create`, and removes the staging directory. `dist/`
is ignored by git. `mise run dmg-check` mounts the image and checks it
([`on-demand-checks.md`](on-demand-checks.md), "The disk image, on
demand"). CI's build job packs one on every push to main and uploads it
([`ci.md`](ci.md)).

The app in it is ad-hoc signed, as the bundle is, and not notarized, so
Gatekeeper blocks its first launch; README.txt says how to open it.
Developer ID signing and notarization are rdm:task/developer-id-notarization.
