# Checks that are not part of the gate

Each of these needs something the gate ([`the-gate.md`](the-gate.md)) must
not need: a display, a container, a quiet machine, the fonts of one
machine, a GPU, or leave to write a crash report or a file of the
repository. Run them when their section says.

## The overflow check, on demand

```sh
mise run ffi-overflow
```

A stack overflow in interpreted Lean code is not caught: the process aborts.
This task shows it. It runs `ffi-test overflow <sysroot> <olean dir>`, which
has Lean's interpreter run a recursion deeper than its stack, and requires
the process to die of SIGABRT after it has printed the line that says it is
entering the recursion. No core file is written.

It is not part of the gate, and must not be added to it. On macOS every abort
makes the system write a crash report for `ffi-test` under
`~/Library/Logs/DiagnosticReports`, and the gate leaves the machine as it
found it. Run it when the Lean toolchain changes, or the way the
executables are linked and started. The gate still builds the scenario and
its fixture.

The entry point gives every thread Lean creates a 64 MiB stack in place of
Lean's gigabyte, so the overflow takes milliseconds; `ffi-test` checks that
size in the gate, without aborting anything. `LEAN_STACK_SIZE_KB` in the
environment overrides it, and both tasks remove the variable.

## The config benchmark, on demand

```sh
mise run config-bench
```

This measures the config session in the executable as built, and asserts
nothing, so it is not part of the gate either. It runs `config-test`'s
benchmark subcommands, each in a fresh process under `/usr/bin/time -l`,
which adds the process's real time and its maximum resident set size:

| Subcommand | Measures |
|---|---|
| `bench-start <sysroot> <olean dir> <module>…` | How long importing the base with those modules takes, and the first load of a 20-line config. Run for `Editor`, for `Editor Std` and for `Editor Lean`. |
| `bench-reload <sysroot> <olean dir>` | The median and the maximum of 20 reloads each of a one-line root, a 20-line config, 50 definitions with a `simp` proof, and a config of two files, the 50 definitions in a config file the root imports, on a base that holds `Lean`. |
| `bench-reload-directory <sysroot> <olean dir>` | The one-line root and the last two of those again, with the config written to and read from a config directory, a temporary one, and not held in memory: the directory's lookups are in the time. |
| `bench-soak <sysroot> <olean dir> <count>` | The mean time of a reload over that many reloads of a config that is its root alone: the 50 definitions in a root that imports `Lean` and uses it. |
| `bench-soak-modules <sysroot> <olean dir> <count>` | The same for a config of two files: a root that imports `Lean` and a config file that changes each round, so each reload writes a module file and makes an environment that imports it. |

Each soak is run with 100 and with 500 reloads by `tools/soak-ratio.sh`,
which prints the subcommand's own line for each and then one line with the
two maximum resident set sizes and the second as a change from the first:

```
bench-soak: resident after 100 reloads 1440.3 MB, after 500 reloads 1440.0 MB: -0.0%
bench-soak-modules: resident after 100 reloads 1635.9 MB, after 500 reloads 1671.9 MB: +2.2%
```

About equal sizes mean replaced configs are freed; the phase that made
config modules set 5% as the bound, and
[lean-runtime.md](../design/lean-runtime.md), "Config and reload", records
the figures and why the second soak grows a little. Memory is reported,
never gating. The second soak takes about three minutes.

A time is from the request for a reload to its report. The config is held in
memory, so the benchmark reads no config file; the soak of two files writes
its module files to a temporary directory of the system's and removes it.
Run it on a quiet machine.

## Converting a config in the old form

```sh
mise run config-migrate                  # ~/.config/leanmacs
mise run config-migrate -- <config dir>  # another directory
```

This converts a config directory from the form the editor no longer loads,
`.lean` files in byte order with no header, to a root `init.lean` and
modules under `Config/` (`tools/config-migrate.sh`, whose header says what
it moves and what it refuses). It is run by hand, on a real config
directory, which is why it is no part of the gate: the gate runs the same
script on a temporary copy of a fixture
([the-gate.md](the-gate.md), "The config directory").

- The files, in byte order, are cut at the first that defines `setup` or
  declares something `private`. For most configs that is the last file.
- Each file before it is moved to `Config/<Name>.lean`, `<Name>` being its
  name without its leading digits, in upper camel case. It gets
  `import Editor`, an import of the file before it, and `open Editor`, so
  each still sees every file before it.
- That file and the ones after it become `init.lean`, in order, each but
  the last in a `section` of its own. So the root itself defines the
  `setup` the editor runs, wherever the old config defined it, and a
  private declaration stays in one module with the files that use it.
- It tells where `setup` is from the text, a line at a time. When no line
  is seen to define it, every file goes in `init.lean`.
- It prints what it did, and changes nothing but the files it moves.
- It refuses, and changes nothing: a directory that already holds an
  `init.lean`; among the files that would move to `Config/`, two that give
  one module name, one whose name gives none, and one whose
  `Config/<Name>.lean` is already there; and a file that would go in
  `init.lean` before another and leaves a namespace, a section or a
  `mutual` block open at its end, which it names: close it in the file, or
  move the definition of `setup` to the last file.

## What config may import, measured on demand

```sh
mise run module-bench
```

This measures, on macOS, what each import set config may use costs an app
bundle (`tools/module-bench.sh`). It is a measurement, not a check, so it
is not part of the gate; the one thing it asserts is that each headless run
it times installed its config, since a rejected reload exits 0 and would be
timed as if it were a start-up. For `Editor` and for `Editor Lean` it prints the modules the
import reads (`config-test bench-modules <sysroot> <olean dir> <module>…`)
and the bytes of each file kind, of whole top-level directories and of those
modules alone; which file kinds the import needs, by staging the whole
directories in a temporary directory with `tools/stage-bundle.sh` with
`olean`, then `olean olean.server`, then `olean olean.server
olean.private`, then that with `ir ir.sig`, and importing from each; and,
with the closure staged with the kinds it needs, five runs of `bench-start`
under `/usr/bin/time -l`. Then, once, the bundle as it was shipped until
the app carried the whole toolchain (packages phase 9): the editor is the
default package set's, which elaborates config on the set's base
(`Editor`, then the entry module of each default package), and a config
file may import `Std` and `Lean`, so the script stages the closure of that
base with `Std` and `Lean` from the directories the build recorded beside
the editor into one directory, `lean/editor`, which `tools/stage-bundle.sh`'s
`--closure` form names in the bundle's record, so the staged editor finds
it with no directory argument, prints its modules and bytes,
and times five runs of that bundle's headless mode with an empty
environment on each of two configs: `tests/headless/generate`, whose root
imports `Editor` alone, and `tests/headless/bundle`, whose root imports
`Lean`, so the base grows to hold it. Every temporary
directory is removed by a trap. It takes about two minutes and a few GB of
temporary disk. The figures, and what they decided, are in
[`lean-runtime.md`](../design/lean-runtime.md), "What config may import,
measured". Run it again when the Lean toolchain's pin moves.

## The bundle, measured on demand

```sh
mise run app && mise run dmg && mise run bundle-bench
```

`tools/bundle-bench.sh`, macOS on arm64 only, measures the built
`Leanmacs.app` and this build's disk image, and asserts nothing but that
each run it times did what it times: the bundle's bytes and files by part
(the toolchain, the core and the default packages, the editor and the
launcher, the Rust archive, the link stubs, the whole); the image's bytes
and its share of GitHub's 2 GiB release-asset limit; the median real time
of 5 headless runs of the bundle's launcher with `env -i`, and the
largest maximum resident set (`/usr/bin/time -l`), on
`tests/headless/generate` (a config of `Editor` alone) and on
`tests/headless/bundle` (a config that imports `Lean`); the time of the
unchanged default set's build from the bundle, the first (which
elaborates the core's lakefile) and a second; and the time of the build
that installs `hello-init`. Everything it writes is in a temporary
directory. It takes about 40 s; its figures of 2026-11-20 are in
[`lean-runtime.md`](../design/lean-runtime.md), "The bundle with the
toolchain, measured".

## The user-side link, on demand

```sh
mise run user-link-check
```

This links an `editor` the way a user's Mac would have to, from pieces the
app ships and with the `clang` and `ld64.lld` the Lean toolchain bundles,
in a sandbox where the Xcode command line tools cannot be reached, and runs
it (`tools/user-link-check.sh`). Unlike the benchmarks it asserts: it exits
non-zero at the first step that does not hold, naming it. It is macOS on
arm64 only, so it is not part of the gate, which runs on Linux too.

It stages, by copy, in a temporary directory: the Lean toolchain; the
`.olean` file and the object of each module the built editor's link names,
the core's and the default packages' (`packages/shipped-themes`,
`packages/compile`), the glue
object and the Rust archive, as `mise run lean` built them (the built
editor is the default package set's, `packages/.lake/build/bin/editor`;
each module is taken from the build directory of the Lake package that
built it, which the record beside the editor, `editor.oleans`, names, and
an object under none of them fails the check; the one object its link
names that is not staged is its generated root's, since the relinked
editor has a root of its own); link stubs for
the system's frameworks and libraries, which `tools/link-stubs.sh` writes
from the built editor's import table; the trivial package
`tests/user-link/package`, one module with one command and its entry
module; the lakefile of the user's side of the link
(`tools/user-link/package/lakefile.lean`); and the relinked editor's root,
which no one writes: the package-set build generates it for the set
`tests/user-link`, the default set and that package (`lake -d
../tests/user-link query :editorRoot` in `lean/`, which writes the root in
that set's ignored build directory and links nothing;
[`lean-runtime.md`](../design/lean-runtime.md), "A link on the user's
machine, measured"). Then it

1. probes the sandbox (`tools/user-link/sandbox.sb`): running
   `/usr/bin/xcrun`, `/usr/bin/clang`, `/usr/bin/ld`, `/usr/bin/cc` and
   `/usr/bin/git`, reading the SDK and listing the real toolchain and the
   repository must each be refused, and the staged `clang` must run;
2. builds the package and links the `editor` inside the sandbox with the
   staged `lake`, with an empty environment and decoys for the developer
   tools first on the `PATH`;
3. signs the result with `codesign --force -s -` and verifies it;
4. runs its headless mode with an empty environment, given the staged
   toolchain and two `.olean` directories joined with `:`, the staged
   pieces' and the one the package's build wrote: the relinked editor's
   config base is its set's, `Editor` and then the entry modules of the
   default packages and of the fixture package, and it has no record of
   where their modules are. It must print exactly
   `tests/headless/expected` for the standing fixture, but for the
   package's command, `user-link-hello`, which each line that lists the
   commands must name once; and for
   `tests/user-link` the package's command must run and say its message in
   the echo area (`tests/user-link/expected`, which holds the echo area's
   text alone, cut from the `scene` line);
5. requires that no decoy ran, that every file the linker opened is under
   the stage, that the build changed none of the staged pieces, and that
   the relinked editor records the built editor's minimum macOS and SDK
   version;
6. prints the machine, the staged pieces with their sizes, the link line,
   and the medians of five runs each of the package build, the whole build
   and link, the link alone and the signing.

```sh
tools/user-link-check.sh lean --linker system
```

is the baseline: the same steps outside the sandbox with `/usr/bin/cc` and
the SDK's frameworks, with the same report, which lists where the linker's
files came from. `--keep` leaves the temporary directory and prints its
path.

Run it from a shell that is not itself sandboxed: when `sandbox-exec`
cannot apply the profile the check fails at its probe, and it never goes on
unsandboxed. It needs `mise run lean` first, which the task runs; the check
itself takes about half a minute. The staged copies are made with `cp -c`,
which clones on APFS; where it cannot clone, the stage is about 3.4 GB. The
build adds the relinked editor, 230 MB. Every temporary file is under one
directory, removed by a trap. The decision it stands behind, the
figures and what was not tried are in
[`lean-runtime.md`](../design/lean-runtime.md), "A link on the user's
machine, measured". Run it again when the Lean toolchain's pin moves, when
the Rust library gains a system dependency, and when macOS or Xcode is
upgraded.

## User package sets, on demand

`mise run user-sets-check` (`tools/user-sets-check.sh`) runs the checks of a
user's package set that need git, Cargo or more builds than the gate's
`user-sets-test` ([packages.md](../design/packages.md), "User package
sets"). It writes in a temporary directory, with `HOME` and `XDG_*` inside
it (Cargo's and rustup's homes kept, so the Rust set builds offline), but
the fixture packages' own `.lake/` and, for the Rust set, the checkout's
`target/`. It ends `user-sets-check: ok`.

- **E, the first launch after an editor update.** A version 1 is built
  from the shipped default. A copy of the shipped default with its
  records, its `editor.core` another core's, is what `leanmacs --data …
  --default <copy> -- --probe` starts, not version 1. Through the
  launcher, the copy's start-up reload builds the set and restarts into
  the new version, which answers `hello-init: initialize ran`. With a
  lakefile naming `broken-elab`, the copy keeps running and the build
  buffer shows Lean's `Type mismatch`.
- **F, git update.** A package in a local repository (`file://`), whose
  lakefile names the core from git as a published package's does (a
  `file://` stand-in for the core's repository, `tools/core-repo.sh`), is
  installed and its pin recorded in `editor.packages`; after a new commit
  `:package-update git-package` moves the pin and builds version 2;
  `:package-update git-package <first rev>` writes `rev` into the
  lakefile and builds version 3 at that pin. Each step runs on the version
  the one before built, so its start-up reload builds nothing. After
  them the lakefile's last require must be `editor-core` by the running
  core's directory, which each edit wrote at the root, and no core may be
  cloned under the config's `.lake/packages`.
- **G, Rust.** A set holding the fixture package `echo`, whose crate the
  editor's Cargo workspace holds, builds with Cargo, and the new editor
  passes its probe. (A crate outside the repository is refused; `ffi-test`
  checks that, `tools/rust-outside-check.sh`.)
- **H, a probe failure.** `init-throws`, whose `initialize` throws in an
  executable called `editor` (Lean runs it when it compiles a module that
  imports it, too, so it does not throw there), builds and links; the new
  editor fails its probe, nothing is published, and the editor keeps
  running.

Measured on macOS arm64 (2026-11-20), the fixture packages and the core
already built: E 10 s, F 17 s, G 5 s, H 6 s; 38 s in all. The gate's
`user-sets-test` takes about 17 s on the same machine, its A's two
successful builds and one failed link about 13 s together.

## The app bundle, on demand

```sh
mise run app-check
```

This builds `Leanmacs.app` from the default package set, at
`packages/.lake/build/Leanmacs.app` (`mise run app`;
[`building.md`](building.md), "The app bundle") and checks it, on macOS on
arm64 only (`tools/app-check.sh lean packages`: the core's directory and
the set's). First it works out the stamp it expects
with the tool `mise run app` stamps with (`leanmacs-release build-id` and
`commit`), and exports it, so its own builds see the same values. When
neither `LEANMACS_BUILD_ID` nor `LEANMACS_COMMIT` was set, it also requires
the two to be HEAD's committer time in UTC and HEAD's SHA as git itself
prints them (`TZ=UTC git log -1 --date=format-local:%Y%m%d%H%M%S
--format=%cd`, `git rev-parse HEAD`), so the stamping tool is not its own
judge; when either was set, as in CI, it takes the values given. In a
temporary directory removed by a trap it copies the bundle with `ditto
--clone`, so what follows runs on a relocated copy, which costs no disk on
APFS; verifies the copy's signature with `codesign --verify --strict
--deep`; reads its `Info.plist` with `plutil` (it lints,
`CFBundleExecutable` is `leanmacs`, the launcher, an executable file under
`Contents/MacOS` beside the `editor` it starts,
`LSArchitecturePriority` starts with arm64, `LSMinimumSystemVersion` is no
later than this machine's macOS, and `CFBundleDocumentTypes` is exactly two
entries, each with `CFBundleTypeRole` `Editor` and one content type,
`public.text` at `LSHandlerRank` `Alternate` then `public.data` at `None`,
read key by key with `plutil -extract`; a walk over the whole plist finds no
`LSHandlerRank` of `Default` or `Owner` and no `UTImportedTypeDeclarations`
or `UTExportedTypeDeclarations`; and both checks are run on mutated copies
that must each fail naming the key: a rank of `Default` on the first entry,
a role of `Viewer` on the second, a second content type, a third entry, and
for the walk a `Default`, an `Owner`, an inserted
`UTExportedTypeDeclarations` and an `Owner` under a dotted key it cannot
address (which fails as `cannot read` that path); `CFBundleShortVersionString`
is the line of `lean/app/version`, read from the file the build reads,
`CFBundleVersion` the expected build ID and `LeanmacsCommit` the expected
commit; `LSApplicationCategoryType` is `public.app-category.developer-tools`
and `NSHumanReadableCopyright` is not empty) and the launcher and the editor
each with `lipo` (arm64 alone) and `vtool` (a `minos` no later than
`LSMinimumSystemVersion`); converts the icon back to an iconset with `iconutil -c
iconset`, which must hold exactly the ten standard images, each read by
ImageIO (`sips`) at its nominal size, 16 to 1024 pixels; and runs the
copy's `editor headless`, through the launcher, on `tests/headless/bundle` with no
directory argument, an empty environment (`env -i`) and `/` as the working
directory, which must exit 0 and print exactly `expected` (the fixture's
root imports `Lean`, so the bundle carries Lean's module files); runs its
`editor headless --generate` the same way on a copy of
`tests/headless/generate`, whose config directory holds `init.lean` alone,
which must load the config, print exactly its `expected`, and leave a
`lean-toolchain` equal to `lean/lean-toolchain` and a `lakefile.toml`
equal to `tests/headless/generate/expected-lakefile-bundle` naming the
copy's `Contents/Resources/lean/set`; and runs the
copy's `editor --version` the same way, which must print exactly the
version, `build <ID>` and `commit <SHA>` lines, so the Lean plist reader
reads the keys the build writes; then the launcher's `--probe` of the
copy's editor, and of a copy of the editor outside the bundle started with
`--default`, each with an empty environment from `/`, must print `probe:
ok`, the launcher, and the copy as CoreFoundation's main bundle with the
app's real identifier, so an editor outside the bundle has the app's
identity (`docs/design/lean-runtime.md`, "The app's identity across an
exec"). Then **a user's package set from the copy alone**
(`tools/bundle-sets.sh`, whose header says each check, as
`bundle-test` runs them on a staged bundle; [`the-gate.md`](the-gate.md),
"The bundle test"): the copy holds every piece a build needs; a first
launch on a config of `init.lean` alone generates the lakefile and builds
nothing; and, with the copy's `Contents/Resources/lean` made read-only
and decoys of `lean`, `lake`, `clang`, `cc`, `ld`, `xcrun`, `cargo` and
`git` first on the `PATH` (and decoy `LEAN_CC`, `CC` and `LEAN_SYSROOT`),
the copy's own `lake` builds the unchanged default set compiling nothing
of the copy, the copy's editor installs `hello-init` from a path and runs
its command, drops the default package `compile` and starts the result,
and builds the C FFI fixture `c-glue` with the bundled `clang`, whose
command answers from its C function. Last, it builds
`editorApp` again and checks that the bundle's executable, its
`CodeResources` and the build's trace file keep their modification times
and inodes: the second build copied and signed nothing. Lake's output is
printed, and holds no `Built «default-set»:editorApp` line. Then, in a
clone of the core and of the default set, `lean/` and `packages/` side by
side in the temporary directory (`cp -c`, so it takes no space), with a
`cargo` that does nothing first on the `PATH`, it swaps the stage script
for one that stages and then fails, builds `editorApp`, which must fail,
puts the script back so the inputs hash to the old trace again, and builds
once more: the bundle must still verify and be the old one, so a failed or
interrupted rebuild leaves no half-built bundle taken as up to date. In the
same clone it writes another version, 9.8.7, into `lean/app/version` and
builds: the bundle must be rebuilt, verify, and name 9.8.7 as
`CFBundleShortVersionString`, with `CFBundleVersion` still the build ID. It turns the artwork, `lean/app/Leanmacs.png`, a quarter
(`sips -r 90`) and builds: the bundle must be rebuilt and verify, and its
icon must hold the ten images with a 1024-pixel one that differs from
before, so the artwork must not look the same turned a quarter. It
writes malformed versions (a trailing space, an empty file, `1.x`, a second
line, four parts) and builds each: each build must fail on the version file
and leave the old bundle. It writes `0.1.0` with no newline after it and
builds: the build must succeed and the bundle name 0.1.0, with
`CFBundleVersion` still the build ID, and the check
must read 0.1.0 from that file as it reads `lean/app/version`, so the two
take the same files. Last, it replaces the artwork with a 512×300 PNG, a
256×256 PNG and a 1024×1024 JPEG and builds each: each build must fail
with an error that `app/Leanmacs.png` must be a 1024x1024 PNG and leave
the old bundle; then it puts the artwork back. It builds with
`LEANMACS_BUILD_ID=20010203040506` and `LEANMACS_COMMIT` forty `a`s
(20010203040507 and forty `b`s when it was given that stamp itself): the
bundle must be rebuilt and verify, name both, and its `editor --version`
must print them. Last, it builds with `LEANMACS_BUILD_ID` unset, `2026` and
`2001020304050x`, and with `LEANMACS_COMMIT` unset, in upper case and 39
digits long: each build must fail naming the variable and leave the old
bundle, which must still verify. It ends `app-check: ok` with the bundle's
size, and takes about four minutes, the steps' times printed beside them
(37 s on 2026-11-17; 70 s on 2026-11-20 with the launcher; 247 s on
2026-11-20 with the toolchain, on an Apple M5 Max: the package-set checks
about 50 s, each of the clone's seven rebuilds about 25 s, as each stages
and signs the whole toolchain again). Its time limit is 600 s. On
2026-11-20 it ended `app-check: ok, 3.6G bundle`.

To see the stamp taken from the environment, as CI gives it, run it once
with both variables set, then rebuild from HEAD:

```sh
LEANMACS_BUILD_ID=20010203040506 LEANMACS_COMMIT=$(printf 'a%.0s' $(seq 40)) mise run app-check
plutil -extract CFBundleVersion raw -o - packages/.lake/build/Leanmacs.app/Contents/Info.plist   # 20010203040506
mise run app
```

It writes nothing outside its temporary directory but that second build,
which is shown to write nothing, opens no window and needs no person. It is
not part of the gate because the gate does not build the bundle, which is
about 3.9 GB and must be signed, and runs on Linux too. It is the check for
any change to `editorApp`, to `tools/stage-bundle.sh` or to module lookup
(`lean/Editor/ModuleLookup.lean`): such a change is not done until this
ends `app-check: ok`. CI's build job runs it on every push to main, before
it packs the disk image ([`ci.md`](ci.md)).

## The restart on a desktop

```sh
mise run restart-check
```

This builds `Leanmacs.app` (`mise run app`) and checks, on this desktop,
what the gate cannot: that a restart keeps the app's identity to
LaunchServices (`tools/restart-check.sh packages`;
`docs/design/lean-runtime.md`, "The app's identity across an exec"). macOS
only. It opens windows, and needs no person. In a temporary directory
removed by a trap, it copies the bundle, sets the copy's
`CFBundleIdentifier` to `org.leanmacs.restart-check`, signs it ad hoc and
verifies it, so the owner's `Leanmacs.app` and a running editor are never
touched; copies the copy's editor to `elsewhere/editor`, outside the
bundle; writes `bad`, which prints `probe: ok` for `--probe` and otherwise
exits 3; and writes the config `tests/restart-check/config/init.lean`,
which restarts into `elsewhere/editor` on entering a `*.restart-elsewhere`
file and into `bad` on a `*.restart-bad` one, each only for a buffer this
run opened (`Buffer.historyRestored` is false), so a restored buffer never
restarts again. Then:

- **A.** It launches the copy cold, `open -n -a <copy> --args --state …
  --config … --sysroot … --oleans …` (the copy's two module directories,
  given so that the editor outside the bundle loads the config too, as a
  restart hands its options on), waits for `lsappinfo` to list an instance
  of the identifier and records its pid, P.
- **B.** It sends the copy an open-file event for `x.restart-elsewhere`
  (`open -a <copy> <file>`): P's config restarts into `elsewhere/editor`,
  after AppKit has checked in. It waits for the hand-over record to appear
  and then go (the hand-shake), and asserts one instance of the identifier,
  with pid P, `bundle path` the copy and name `Leanmacs`, and that P now
  runs `elsewhere/editor` (`ps -o comm=`).
- **C.** An open-file event for `after.txt` must reach that executable:
  within 10 s the newest index lists it.
- **D.** An open-file event for `y.restart-bad`: P restarts into `bad`,
  which fails; the launcher's watcher, a process LaunchServices did not
  launch, starts the previous executable, `elsewhere/editor`, as a new pid
  Q. It asserts the hand-shake, one instance, with pid Q and the copy's
  bundle path, that Q runs `elsewhere/editor`, and that an open-file event
  for `after2.txt` reaches Q.

It ends Q and prints `restart-check: ok` with both pids and paths; a
failure names the step and prints what `lsappinfo` says of the identifier.
It takes about 15 s. Its first run, on 2026-11-20 on an Apple M5 Max under
macOS 27.2.1, passed every step; `docs/design/lean-runtime.md` keeps its
output. Run it after a change to the launcher (`crates/editor-launch`,
`crates/editor-launch-std`), to how the editor execs, to the bundle's
`Info.plist`, or to the window's start-up.

## The disk image, on demand

```sh
mise run dmg && mise run dmg-check
```

`mise run dmg` packs `dist/Leanmacs-<build-id>.dmg`
([`building.md`](building.md), "The disk image"). `mise run dmg-check`,
macOS only, checks it: it fails, saying to run `mise run dmg`, when this
build's image is not in `dist/`, and otherwise runs the ignored test
`crates/editor-release-std/tests/dmg_mount.rs` with `LEANMACS_DMG` naming
the image (the test panics when that is unset). The test mounts the image
read-only, with no Finder window, on a mount point in a temporary directory
it owns, and detaches it however it ends. Then:

- the volume's root, read without following links, must be exactly
  `Leanmacs.app` (a directory), `Applications` (a link to `/Applications`),
  `LICENSE` and `README.txt` (files), compared by
  `editor_release::dmg::check_volume`, whose unit tests in the gate pin
  every way it can differ. Names that start with `.` are left out:
  `hdiutil` may add `.fseventsd`, which Finder hides;
- `LICENSE` and `README.txt` must hold the bytes of the repository's
  `LICENSE` and `packaging/macos/README.txt`;
- the app's signature must verify (`codesign --verify --strict --deep`);
- its `CFBundleVersion` must be the build the file name names and this
  build's ID, its `LeanmacsCommit` this build's commit, and its
  `CFBundleShortVersionString` the line of `lean/app/version`;
- its `editor --version`, run with an empty environment, must print those
  three;
- a user's package set must build from the read-only volume alone: the
  image's `leanmacs headless --generate`, on a temporary config of
  `tests/headless/generate`'s `init.lean`, writes a lakefile naming the
  volume's set, and the volume's own `lake -d <config> build
  :editorInstall`, with an empty environment but `PATH=/usr/bin:/bin`,
  `HOME` in the temporary directory and the app's `editor.build`, exits 0
  and installs an editor with the app's core that starts. The volume is
  read-only, so nothing of the app was compiled.

It writes nothing but the mount point, the config, a home and the install,
all in its temporary directory, and takes about 40 s (2026-11-20: 39 s, an
image of 1,216,656,359 bytes; `mise run dmg` packed it in 97 s). It ends
`dmg-check: <image> holds the app (build <id>, commit <sha>), the link,
the licence and the README, and the default set built from the read-only
volume alone`. It does not
depend on `dmg`, so CI's build job, which runs `dmg` then `dmg-check`,
packs once. It is not part of the gate, which builds no bundle.

## The nightly's preparation, on demand

```sh
mise run nightly-check
```

macOS only. The ignored test `crates/editor-release-std/tests/nightly_mount.rs`
stages a tiny `Leanmacs.app/Contents/Info.plist` stamped with a build ID
and a commit, packs it with `hdiutil create` as `Leanmacs-<id>.dmg` in a
temporary directory it owns, and runs the nightly's preparation
(`editor_release::nightly::prepare`, as `mise run nightly` does) on it
through the real process adapter, with real `hdiutil`, `plutil` and
`shasum`:

- for the stamp's own build and commit, the output holds exactly the two
  images, `Leanmacs.dmg.sha256`, `build.json` and `notes.md`;
  `shasum -a 256 -c Leanmacs.dmg.sha256` passes; `build.json` and the
  checksum read back as the build; and the image is detached;
- for another commit, the preparation refuses with the mismatch, copies
  nothing, and the image is detached all the same.

It writes nothing outside its temporary directory and takes a few seconds.
`mise run nightly`, after `mise run dmg`, prepares the real assets in
`target/nightly` ([`building.md`](building.md), "The nightly's assets").

## Installing the app

```sh
mise run install
```

This installs the app to use, on macOS on arm64 only. After `mise run
app-check`, `tools/install-app.sh` replaces `/Applications/Leanmacs.app`
with the built bundle, the default package set's
(`packages/.lake/build/Leanmacs.app`), by `ditto`, and verifies its
signature. When
`~/.config/leanmacs` does not exist it installs the default config
`config/default` there, its root `init.lean` and the config file
`Config/Leader.lean`, a starter `SPC` map (which the gate's
`config-test` loads, [`the-gate.md`](the-gate.md)); an existing config is
never touched, and the script only says where the default config is. It
keeps no backups, since any commit's app can be rebuilt, and deletes the
`Leanmacs.app.backup-*` and `~/.config/leanmacs.backup-*` directories the
earlier install script left. It opens, registers or runs nothing.

## The job benchmark, on demand

```sh
mise run job-bench
```

This measures the latency of the editor loop while background jobs run, in
the executable as built, and asserts nothing, so it is not part of the gate
either. It runs `config-test bench-jobs <sysroot> <olean dir> 10000`. A
sample is the time from posting a request to run a command that does nothing
to the editor thread having run it. It takes 10,000 samples in each of five
rows and prints the median, the 99th percentile and the maximum of each, in
microseconds:

| Row | What runs meanwhile |
|---|---|
| idle | Nothing. |
| 64 jobs each sleeping 1 ms | 64 jobs from config, each sleeping a millisecond in a loop: every wait goes through the timer service and the completion pump. |
| one job a pool thread computing | Interpreted jobs that compute for ever, one for each thread of Lean's task pool. |
| two jobs a pool thread computing | Twice as many: half run and half wait in the pool's queue. |
| idle again | Nothing. |

It then times a million `now` requests in one compiled job, and says which
of the three loaded rows are within bound: a row whose median is at most
twice the larger of the two idle medians and whose 99th percentile is under
100 µs. That is an observation about one run, and the maximum is printed and
not judged. Run it on a quiet machine.

## The prompt benchmark, on demand

```sh
mise run prompt-bench
```

This measures what a key costs in a prompt over many candidates, listed on
the editor thread and matched off it, in the executable as built, and
asserts nothing, so it is not part of the gate either; the gate builds the
subcommand. It runs `config-test bench-prompt <sysroot> <olean dir> 600`.
Each row is a headless host on the real queue and the library, the
matcher among it, its candidates paths of about 40 bytes. A sample is one
key of the six of `src/f1`, committed into the open prompt as typed text,
and a `run noop` sent right after it: the time from sending the key to the
editor thread printing that it ran `noop`, read on the editor thread. After
the sixth key the prompt is cancelled and asked again, untimed. It takes 600
samples a row and prints the median, the 99th percentile and the maximum of
each, in microseconds:

| Row | The prompt |
|---|---|
| no candidates | A prompt with none: the floor, a key's step and the empty one after it. |
| 100, 250, 500, 1,000 and 10,000 inline | That many listed on the editor thread, the inline limit lifted. |
| 100,000 inline (limit lifted) | The path before matching moved off the editor thread. |
| 100,000 on the worker | Matched by a match job, each key joined: the next key finds no match in flight. Also printed: the listing's latency, from the key to the editor thread having run the match job's command. |
| 100,000 on the worker, keys 20 ms apart | Matched by a match job, nothing joined: each key arrives while a match runs or while its delivery is handled. |
| open-file, 10,000 entries | `open-file`'s prompt (completion's phase 6) on a host of the test scheme whose jobs reach a fake file service holding one directory of 10,000 files, the host's working directory: the prompt lists it once, joined and untimed; each timed key is typed within the directory, so no listing is started for it and the match job runs the `path` style off the editor thread; each key is joined. The keys are `f`, `1` to `5`. |
| insert, no at-point | Completion at point's baseline (completion's phase 5): a host of the Vim scheme that ships, as `ConfigTest.withVimHost` builds one, on a fake job clock of its own and the real library, queue and recorder, with no at-point source used, so nothing is armed. Each sample types two word keys, then four more, in insert state, each timed, then `<Escape>` and `u`, untimed. |
| insert, auto popup, 20 buffers | The same host with the shipped `words` used in every buffer, over 20 open buffers of about 50 KB of generated words each (`word<i % 4999>_<i % 4999 % 97>`, about 5,000 distinct): each typed key re-arms the pause. After the first two keys the clock is moved 240 ms and the `words` job joined, untimed, so the next four keys are typed with the session open, its listing matched off the thread. |

It says whether the two rows on the worker and the `open-file` row are
within bound: median at most twice the no-candidates median and 99th
percentile under 1 ms. **The `open-file` row out of bound fails completion
phase 6's performance budget**, as a worker row fails phase 3's. On a
line of its own it says whether the auto-popup row is: median at most twice
the `insert, no at-point` median, the same key with no at-point source, and
99th percentile under 1 ms. **A worker row out of bound fails completion phase
3's criterion 4, and the auto-popup row out of bound fails phase 5's
budget for a typed key**: report it, do not only print it. It also names the inline rows whose 99th percentile is under
1 ms, which is how `Loop.inlineMatches` was set. The recorded run is in
[`docs/design/concurrency.md`](../design/concurrency.md), "Matching off the
editor thread, measured". Run it on a quiet machine.

## The workspace finder benchmark, on demand

```sh
mise run find-file-bench
WORKSPACE_BENCH_REPO=/path/to/a/checkout mise run find-file-bench
```

This measures what a key costs in `find-file-in-workspace`'s prompt over a
real repository, and the time from a key to the list it updates, in the
executable as built, and asserts nothing, so it is not part of the gate;
the gate builds the subcommand under every linter (`lean`) and never runs
it. It needs fzf on the `PATH`, which `mise.toml` pins and the task's
environment puts there.

The repository is made by `tools/workspace-bench-repo.sh <dir> [count]` in
a temporary directory that the task removes on exit: 100,000 files at
`src/m<i / 100>/f<i>.rs`, each holding its own number, committed once on
`main` by a fixed author at a fixed date, git reading neither the user's
nor the system's config, so a run can be repeated on another machine.
`WORKSPACE_BENCH_REPO` names a checkout to measure instead. The task runs
`config-test bench-workspace-files <sysroot> <olean dir> <repository> 120`,
with `LEAN_NUM_THREADS` and `LEAN_STACK_SIZE_KB` removed from the
environment.

It is one headless host of the test scheme over the library's real process
and file services and its queue, its working directory the repository,
registered with the file commands, the minibuffer's and the workspace
commands, their jobs and sources. It opens `src/m0/f0.rs` and joins, which
runs the git finder; runs `find-file-in-workspace` and joins, the first
listing, and prints the prompt's status line, which names the workspace
(`repo@main`, so git found it). A sample is one key of `m`, `1`, `2`, `f`,
`3` and `4`, committed into the open prompt as typed text, and a `run
noop` sent right after it; after the sixth key the prompt is cancelled and
asked again, untimed. It takes 120 samples a row and prints the median,
the 99th percentile and the maximum of each, in microseconds:

| Row | What is timed |
|---|---|
| no candidates | A key in a prompt with no sources, on the same host: the floor. |
| workspace finder, each key joined | From sending the key to the editor thread printing that it ran `noop`: the key's handling and its publish. Each key is joined, so the next finds no job in flight. |
| key to the updated list | From sending the same key to the editor thread having run the post of the source's batch for its text (`job <id> workspace-files: ok`): the source's 50 ms pause, `git ls-files` and fzf on the pool, and the listing of the batch. |
| workspace finder, keys 120 ms apart | The key alone, nothing joined: each arrives, after the pause, while the job of the text before it runs its lister or its filter, or while its batch is listed. |

Then it runs the lister, `git ls-files -z --cached --others
--exclude-standard`, and the filter, `fzf --read0 --print0 --filter m12`
fed its output, each 20 times outside the editor, and prints their
medians, so the listing's latency can be read against them. It says
whether the two finder rows' keys are within bound: median at most twice
the no-candidates median and 99th percentile under 1 ms, the bound
project navigation phase 2's plan set. **Report a finder row out of
bound**, do not only print it. Phase 2's last criterion is that no key
waits on the lister or the filter, which the gap between the finder rows
and the key-to-list row shows; the recorded runs meet it, while both
finder rows' medians are more than twice the floor, because the editor
thread re-marks the passed candidates on every key. The rdm task
`mark-filtered-candidates-once-per-batch` is the work that brings them
back within the bound. The recorded runs are in
[`docs/design/concurrency.md`](../design/concurrency.md), "A key in the
workspace finder, measured". Run it on a quiet machine.

## The syntax round, measured on demand

```sh
mise run syntax-bench
```

This times the syntax rounds on the largest Lean file in the repository,
which the task finds on every run, through the real tree-sitter adapter in
a release build, and asserts nothing, so it is not part of the gate, which
only builds it. It is the example of `crates/editor-syntax-treesitter`
(`examples/round.rs`), which takes any path and grammar name. It prints
the file's bytes and lines, the grammar's reparse policy and its tree's
error nodes, the time of the first parse, and the median, minimum and
maximum of 20 rounds after an edit (`Session::parse_once`) and of 20 idle
refreshes (a whole parse and its compare, `Session::refresh_once`).

Run it on a quiet machine when the Lean grammar is updated
(`vendor/README.md`) or the round changes, and record its figures, dated, in
`docs/design/rust-library.md` ("Lean, measured"), naming the file it
timed. The task finds the largest Lean file with `find lean tests -name
'*.lean' -not -path '*/.lake/*' | xargs ls -S | head -1`.

## The keyboard check, on demand

```sh
mise run window-check
```

This opens a window and reports what of the keyboard reached a Lean loop. It
needs a display, so it is not part of the gate. It runs `editor
window-check`: the real window, opened through the entry point on the
process's main thread, and a loop on a dedicated Lean task that pulls the
editor queue, as the command loop will. It counts what is typed in the
window until the window closes. The report is eight lines on stdout:

```
window-check: composition <on|off>, limit <n> s; the main-thread service is on the process's main thread: <yes|no>
window: opened by <platform> <ms> ms after it was asked for        (or "could not open: <reason>")
focus: gained <ms> ms after the window opened; first pointer press in the window: <ms> ms after it opened
                                                                    (or "never gained", and "none")
keys: <n> key events reached the Lean loop (<p> presses, <t> of them repeats, <r> releases); text: "<the first 60 characters typed>"
latency from a key's arrival in Rust to its handling in Lean, in µs: median <m> / 99th percentile <p> / maximum <x> (<n> samples)
                                                                    (or "no samples")
dead keys: <n> key events marked dead
composition: <enabled|not enabled>; <a> preedit and <b> commit events; committed: "<the first 60 characters>"
ended: the window was closed                                        (or "the time limit", or "the window never opened")
```

A key's latency is the time from the instant the window's loop was handed
the key, read in Rust on the main thread, to the instant the Lean loop had
pulled the event and read the same clock. Every key event is a sample. The
check decides nothing about what a key means: it shows that keys, dead keys
and an input method's composition arrive.

| Option | Does |
|---|---|
| `mise run window-check -- --no-ime` | Runs the window with composition not allowed, so a dead key arrives as a key marked dead. Seen on Linux under Xvfb. |
| `mise run window-check -- --seconds <n>` | Closes the window after that many seconds if nobody has (120 by default). |

The exit status is 0 when the window ran, 1 when it could not be opened and
2 when the options are not understood. A window that ran and never reported
that it opened counts as one that could not be opened, in the report and in
the status. The gate runs the same loop on the
scripted platform (`ffi-test`) and on a fake (`lean-test`), with no window,
and checks there what each option asks for.

## The window's contract, on a desktop

```sh
mise run window-contract
```

It opens two windows on this desktop, one after the other, so it is not
part of the gate, which builds both programs and runs neither. Of the
second it runs the unit tests, which open no window. Both programs also
run in the container, under Xvfb, as parts 1 and 4 of `linux-window`.

**The first** holds the real window to the window port's contract
(`crates/editor-platform`, `contract`): it opens, it tells whatever draws
in it that it opened before it reports so to anyone, it reports that it
opened before anything else, it returns when it is asked to close from
another thread and not before, even if it was asked to close before it
opened, it tells the drawer it is closing, once, last, and no resize it
reports in fullscreen says a corner clearance. The window opens for about
a second. It is the example of `crates/editor-platform-winit`, and it
prints the verdict on one line and then each resize the window reported,
one line apiece: `window-contract: resized <w>x<h> scale <s> fullscreen
<bool> corner <n> top <n>`. Its window opens with the themed title bar,
the options' default. On macOS it is also asked for a menu bar while it
runs, which it reads back from AppKit (exactly the menu asked, with the
services and windows menus set and no fullscreen item of AppKit's), and
whose command items and Quit it performs; then it is asked to quit as the
system asks, and then starts itself again in a second process and
window, where a close with the system's quit pending must let AppKit end
the process with status 0, only after that process recorded its verdict.

**The second** is the window that draws: the example `window` of
`crates/editor-ffi` (`examples/window/`). The real window is run onto a
queue with a render session as its drawer, and the session's renderer is
the wgpu renderer on the window's surface, on this machine's GPU. A second
thread stands in for the editor: when it learns the window's size and
scale it tells its layout the scale, lays out a fixture frame with the
real shaper over the fixture fonts, and publishes it. The fixture's text
is 14 points, so it is 14 physical pixels on a display at scale 1 and 28
at scale 2. The window stays for 20 seconds once it is ready, or until it
is closed; `cargo run --locked --package editor-ffi --example window --
--seconds <n>` runs it for another time.

The first prints `window-contract: the winit platform keeps the window
port's contract`, then its resizes. On macOS each of them must say
`fullscreen false`, a corner above 0 and a top above 0: the run never
asks for fullscreen, so it shows nothing of the fullscreen case, which
rests on the adapter's own tests (`corner.rs`, `title_bar.rs`,
`translate.rs`). How the two fallbacks were measured is below ("The
corner clearance, measured", "The title bar's top inset, measured"). The
second fails, with a line beginning `window:
FAILED:` and exit status 1, unless all of these hold:

- each frame it publishes is laid out at the window's scale: it prints
  `window: frame <n> is laid out for <w> by <h> at scale <s>: 14 points
  are <p> pixels` for each, and `<p>` must be 14 times `<s>`;
- a frame was presented, and each frame's picture, read back from the
  surface, is within 3 of 255 of the headless renderer's. A picture that
  could not be read back fails the run. A surface that says it does not
  let its texture be copied from prints that the frame's picture was not
  compared, which this task does not fail (`--require-picture` does);
- no draw is for nothing that was asked, there are no more draws than
  things that asked for one, and nothing is drawn over the idle second,
  which begins once the window has drawn what was asked as it opened (or
  after five seconds), but for a frame or two a system asks for as it
  uncovers the window;
- each time the window is left alone, it shows what was laid out for it
  ("Left alone", below);
- at least one key or pointer input came off the queue. Each input is
  printed on a line beginning `input:`.

It also prints the adapter and the back end the renderer is on, a
timeline of each thing that asked for a draw and each draw (`window: at
<t> ms: <what>`, with the masks each presented draw's glyphs were drawn
with), and the journal's account of each frame presented. It ends
`window: the window drew the fixture frame, drew nothing it was not asked
for, and its input arrived on the queue`, with exit status 0. Do not
loosen the 3 to make it pass: a difference past it is a finding.

| Option of the example | Does |
|---|---|
| `--seconds <n>` | Closes the window that many seconds after it is ready, if nobody has (20 by default). |
| `--require-picture` | Fails the run unless every frame's picture was read back and compared: a surface that does not let its texture be copied from is then a failure too. `linux-window` gives it; this task does not, since a desktop's surface may be such a one. |
| `--until-closed` | The window stays until it is closed. Not understood with `--seconds`. The timeline then prints up to 5000 lines, not 300. `window-by-hand` gives it. |
| `--no-picture` | No picture is read back and none is compared: the run prints `window: pictures were not read back (--no-picture): the picture was not checked in this run`, once, and fails for no picture. Not understood with `--require-picture`. `window-by-hand` gives it: reading a picture back and comparing it takes about half a second a draw at 1600 by 1200, which makes every step of a resize look stalled. |
| `--family <name>` | Lays the fixture out in that family of this machine's fonts, in place of the fixture fonts, and prints `window: the fixture is laid out in <name>, of this machine's fonts` first. A family the machine has not fails the run before any window opens (`window: FAILED: this machine has no font family named <name>, of its <n> families`). No task gives it. |

**Left alone.** A window is left alone when a second passes in which it
tells its drawer nothing, no frame is published and no draw begins or
ends; the example's own idle second is the first such time. Each such
time, if the window has not said it is hidden, a frame has been presented
and no draw is in progress, the draw last presented must be of a frame
laid out for the size and the scale the window last said, on that size
and scale. Otherwise the run fails: `window: FAILED: left alone from <t>
ms after it opened, the window showed frame <n>, laid out for <w> by <h>
at scale <s>, on <w> by <h> at scale <s>, when it had last said it is <w>
by <h> at scale <s>`. A window that was never left alone while it showed
a frame prints `window: the window was never left alone for a second
while it showed a frame, so what it shows when it is left alone was not
judged`, which is no failure by itself. What the window shows between two
sizes, while it is not left alone, is not judged.

What the example makes of what it saw (how these options are read, which
of them contradict each other, which findings of a picture fail which
run, which sizes a frame's glyphs are drawn at and which of them fail,
what the timeline says of a draw's masks, and which ledgers show a window
left alone with something not laid out for it) is tested in the gate, by
the example's own unit tests, which open no window.

### What the first desktop run showed

It was first run on 2026-11-14 on macOS (aarch64, Apple M5 Max, Metal, a
display at scale 2 that refreshes at 120 hertz). The first program passed.
The second's picture held, on a surface that lets its texture be copied
from: 31 of 1920000 pixels differed from the headless renderer's, the
worst by 1 of 255. It failed on the check's own count, and four things
were found, the first three since changed:

- **The idle second was measured wrongly.** On macOS the system asks for
  a window's content a few milliseconds after it opens (`drawRect:`,
  which the adapter tells as damage), while the first draw is still
  running; the damage was answered by a second draw that the idle second
  counted. Under Xvfb the damage comes before the first frame is
  published, and one draw answers both. The example now enters what asks
  and what is drawn in one ledger, judges each draw by what it was for,
  and begins the idle second once what was asked as the window opened is
  drawn (`crates/editor-ffi/examples/window/main.rs`, "The ledger").
- **A window that opens is not on the screen at once, and does not say
  so.** Started from a process not in front, the surface answered
  `Occluded` for the window's first 140 ms and the window told nothing
  until `Hidden(false)`, while the render loop tried the refused draw
  again every refresh. A draw refused because nobody can see its target
  now says so, and the loop waits to be told more (`editor-render`'s
  `render_loop`, "A hidden target").
- **A click arrived as a press, a drag and a release, all at one place.**
  winit on macOS says where the pointer is before every press and every
  release. Being told the pointer is where it already was is no longer a
  drag.
- **The window said its size four times as it opened, the same each
  time**: once from the adapter, straight after `Opened`, and three times
  from winit, which says the size at each step of building the window.
  They are reported as winit says them; nothing is drawn for them. An
  editor that lays out at every resize lays out four times as it opens
  there.

On the tree with the three changes, the second program, started so that
its window was not on the screen at once, exited 0: two draws refused as
`Occluded`, one presented after `Hidden(false)`, nothing drawn over the
idle second, and a click arriving as a press and a release.

### The corner clearance, measured

The adapter reports the system's own reading of how far in a window's
rounded bottom corners reach (`crates/editor-platform-winit/src/corner.rs`:
the content view's safe-area layout region adapted to the corners
horizontally, macOS 26 and later), rounded up to a whole point, and a
fallback, `FALLBACK_POINTS`, when the system gives no reading above 0. The
fallback was measured on 2026-11-16 on a Mac17,7 (arm64) running macOS
27.2 (26B123): with the constant set to 0 for the run, and a line printing
the insets the system gave added for the run, `mise run window-contract`
read the insets left 16, right 16, top 0 and bottom 0, printed two
resizes, both `resized 1600x1200 scale 2 fullscreen false corner 16`, and
passed. The constant is 16. With it restored the run printed the same.
That is winit's window, which has a title bar and no toolbar; the system
gives a window with a toolbar larger corners. To measure it again, set
the constant to 0, run the task, read the `corner` of the resizes, and
set it back to what they say.

The window's content view has extended under its title bar since the
themed title bar (theming phase 7), and the reading changed with it. On
2026-11-16, on the same machine and system, with the constant set to 0
for the run and the insets printed, the corner-adapted region read left
78, right 16, top 32 and bottom 0: the left inset now takes in the
window's buttons, at the top left, and the run printed `corner 78`. The
adapter now takes the nearer of the two sides (`corner::reach`), and the
run printed `corner 16` on every resize with the constant at 0 and at 16
alike. The constant stays 16.

### The title bar's top inset, measured

With the themed title bar the adapter reports how far down the title bar
covers the content view (`crates/editor-platform-winit/src/title_bar.rs`):
the top of winit's `Window::safe_area`, which winit-appkit reads from the
content view's `safeAreaInsets`, over the scale factor and rounded up to a
whole point, and a fallback, `FALLBACK_POINTS`, when the system gives no
reading above 0. The fallback was measured on 2026-11-16 on a Mac17,7
(arm64) running macOS 27.2 (26B123): with the constant set to 0 for the
run, and a line printing the insets the system gave added for the run,
`mise run window-contract` read `safeAreaInsets` top 32 and left, right
and bottom 0, printed two resizes, both `resized 1600x1200 scale 2
fullscreen false corner 16 top 32`, and passed. The constant is 32. With
it restored the run printed the same. To measure it again, set the
constant to 0, run the task, read the `top` of the resizes, and set it
back to what they say. A standard title bar (`titleBar .standard` in
config) reports 0 whatever the system reads, and so does a window in
fullscreen.

### The window at the macOS weight

On 2026-11-14, on the same machine, the second program presented one
frame in plain masks at scale 2 at the macOS weight
(`Settings::core_text()`), and 64 of its 1920000 pixels differed from the
headless renderer's at the same settings, the worst by 1 of 255: on
Metal the window's picture at the macOS weight is the headless
renderer's.

## The window to try, on demand

```sh
mise run window-by-hand
```

This opens the window that draws (the second program of
`window-contract`, above) with `--until-closed --no-picture` and leaves it
open until it is closed, its own checks running, for trying the window
out. `cargo run --locked --package editor-ffi --example window --
--until-closed --no-picture --family <name>` lays the fixture out in a
family of this machine's fonts in place of the fixture's Noto Sans.

### The window's scale, as seen

On 2026-11-14, on a macOS desktop at scale 2 (Apple M5 Max, Metal), the
window's first frame was laid out at scale 2, its 14 points drawn at 28
pixels. With the example changed for the run so that it did not tell its
layout the scale, the run failed with `frame 1 is laid out for a window
at scale 2, where 14 points are 28 pixels, and its glyphs are drawn at 14
pixels`. In the container, `mise run linux-window` shows the scale
reaching layout each time it is run, at a scale of 2 winit is told and
across a change of scale from 1 to 2 ("The window on Linux, on demand",
part 4). Not seen: a window moved between two displays, a change of scale
from 2 to 1, the system's fullscreen, another Space.

## The system's fonts, on demand

```sh
mise run shaper-system
```

This holds the real shaper over the fonts of this machine
(`FontSet::system` in `crates/editor-shape-parley`) to the shaper port's
contract (`crates/editor-layout`, `shaper::contract`). What it finds
depends on the fonts installed, so it is not part of the gate, which only
builds it: every test of the adapter runs on the fixture fonts under
`tests/fonts`, and the crate's `clippy.toml` forbids the system's fonts to
them. It is the example of `crates/editor-shape-parley`
(`examples/system.rs`). It prints the family the default font is shaped in
and how many families the machine has, then either that all the
contract's properties hold or the name of each that fails; its exit status
is the result.

Run it when the pin of Parley or fontique moves, and when
`FontSet::system` changes. It has been run on macOS, where the default
family was Courier of 557 families and every property held. It has not
been run on Linux: the container of `linux-ci` has no fonts installed.

## The wait inventory, on demand

```sh
mise run wait-inventory
```

A wait with a bound left in a test says which kind of bound it is
(AGENTS.md, "Deterministic concurrency in tests"), in a comment on its line
or among the three lines above it, or at the head of the doc of the
constant or function it passes as its bound, in one of three forms:

- `hang guard: <the event the wait ends on>; only a hang reaches the bound, and the check then fails as a hang.`
- `hang guard, run out on purpose: <what is held for good>; the check pins the hang.`
- `real time under test: <the timing that is the subject>.`

This task (`tools/wait-inventory.sh`) lists the sites that do not. It reads
the Lean test roots and test support (the four roots, `lean/Editor/Test/`,
the contract checks `lean/Editor/**/*Contract.lean`, the packages' `*Test`
trees, and the headless driver's waits in `lean/Editor/Headless.lean`,
`Window/Real.lean` and `Job/Pool.lean`), and the Rust tests, examples and
benches, the published test support (`contract`, `fake`, `scripted`,
`tests.rs`, `tests/`) and each other source file from its first
`#[cfg(test)]`. It drops comments and string literals, then takes as a site
each line whose code holds a wait: in Lean `IO.sleep`, `eventually`, a bare
`within` or `Headless.within`/`Pool.within`/`Session.within`, `monoMsNow` or a name holding `patience` or ending in `Guard`; in
Rust a `sleep(` call (but one on a receiver named `fake…`, which moves a
fake clock), `recv_timeout`, `wait_timeout*`, `park_timeout`, `yield_now`,
`Instant::now() +`, `.elapsed()`, or `is_finished()` or `try_wait()` in a
`while` condition. It prints the explained count by kind, then the unexplained
count and each such `file:line`, and exits 1 when there is one; `--list`
prints every site with its kind.

It is a review aid, never part of the gate or hk: a check that scans source
text breaks on changes that do not matter (AGENTS.md, "Test behaviour, never
text"). It matches a named bound by its last dotted segment, so it points a
reviewer at sites and proves nothing about them. What shows the tests do not
depend on time is the stress loop (below) and the forced-interleaving checks.

## The stress loop, on demand

```sh
mise run stress -- 50 config contract rust open-file
mise run stress -- 10 ffi
mise run linux-stress -- 50 config contract rust open-file
```

A check whose result hangs on how threads are scheduled or how fast the
machine is passes on an idle laptop and fails on a loaded runner
(AGENTS.md, "Deterministic concurrency in tests"). The stress loop
(`tools/stress.sh <rounds> [suite ...]`) runs the gate's thread-heavy suites
that many rounds under a load of `2 x cores` processes of `yes >/dev/null`
(`sysctl -n hw.ncpu` on macOS, `nproc` on Linux; `STRESS_HOGS` overrides),
each suite in the foreground under `taskpolicy -c utility` on macOS and
`nice -n 19` on Linux, so the hogs win the CPU. The suites:

| Suite | Runs |
|---|---|
| `config` | `config-test`, as the gate runs it, from `lean/` |
| `contract` | `contract-test`, as the gate runs it |
| `rust` | `cargo test --workspace --locked` |
| `open-file` | the open-file headless fixture, exactly as `ffi-test` runs it |
| `ffi` | `mise run ffi-test`, every headless fixture |

With no suite named it runs the first four. Run it after `mise run ci` has
built everything: it builds nothing, and `cargo test` would build a changed
tree inside the loop. Each run's output goes to
`$STRESS_OUT/<suite>-<round>.log` (a fresh temporary directory when it is
unset). It prints `<suite>: <passed>/<rounds>` for each suite, then each
failing run with the `FAILED:` lines of the Lean checks or the failing
Rust tests' names, and exits 1 on any failure. A trap kills the hogs on
exit or interrupt, so nothing is left running.

The open-file fixture was the named case: it pinned the count of scenes
published, which the syntax worker's deliveries vary under load (21 of 30
loaded runs failed at 042e3b40). With the count out of the scene line
(`published`, [headless-mode.md](headless-mode.md)), `mise run stress -- 50
open-file` at 5142a367 on an 18-core Mac under 36 hogs printed
`open-file: 50/50`.

A failure is a bug, in a check or in the code. It is fixed and the loop is
run again from round 1, never retried away. A bound that a loaded run
reaches on an event that does come is a hang guard set too short: it is
raised to ten times the slowest that event was seen to take, and the
measurement goes in its doc.

`mise run linux-stress` runs the same loop in the Linux container of
`linux-ci` ([below](#the-gate-on-linux-on-demand)), after one `mise run ci`
there, with `2 x nproc` hogs of the container's CPUs; its logs are in
`.linux-ci/work/stress-logs/`. It is evidence for the Linux code paths
(pidfd, inotify, glibc), on the machine's own architecture, not for the
ubuntu runner. `.github/workflows/stress.yml` runs the loop on
`ubuntu-24.04`, on dispatch only: five shards of ten rounds, and a summary
job that adds them up and must print each suite's `50/50`
([ci.md](ci.md#the-stress-loop-on-dispatch-only)).

## The gate on Linux, on demand

```sh
mise run linux-ci
```

This runs `mise run ci` on Linux, in a container. It needs Docker and, the
first time, the network, so it is not part of the gate. `tools/linux/run.sh`
builds the image `tools/linux/Dockerfile` describes (Debian 13 with the
system compiler, mise and elan, each pinned), copies the checkout into a work
directory, and runs the gate there. The copy is the tracked files and the
untracked files git does not ignore, so uncommitted work is tested and this
machine's own build output is not touched. The exit status is the gate's.

| Where | What |
|---|---|
| `.linux-ci/home/` | The toolchains: rustup's, elan's, mise's installs. About 4.6 GB. |
| `.linux-ci/work/` | The copy of the source, with the core's Lake build output and the formatter's clone (`lean/.lake`). About 1.2 GB. |
| The Docker volume `editor-linux-ci-cargo` | Cargo's home and `target/`. They must not be on a directory mounted from macOS: clean runs failed there. About 1.4 GB. |
| The Docker image `editor-linux-ci` | The system packages, mise and elan. About 0.9 GB. |

`.linux-ci/` is at the root of the checkout and ignored by git; set
`EDITOR_LINUX_CACHE` to put it elsewhere. `mise run linux-ci -- --clean`
empties the copy's build output first and keeps the toolchains and Cargo's
registry: everything is compiled again and nothing is downloaded again.

Only `lean/.lake` is kept in the copy from one run to the next: the copy
step removes everything else before it copies, the build output of the
package sets and of the fixture packages among it (`packages/.lake`,
`tests/packages/**/.lake`). So every run, clean or not, writes the two
generated roots again, rebuilds the fixture packages and links both
editors, on top of the core's modules, which are kept. That was chosen
over keeping those directories: it is seconds, and the copy step stays one
rule. `--clean` therefore empties what it did before and nothing more. Not
run since the editor came from a package set (packages phase 4): Docker
was not at hand.

It runs on the machine's own architecture. It has been run on aarch64, not
on x86_64.

## The window on Linux, on demand

```sh
mise run linux-window
```

This is where the winit adapter is held to the window port's contract
without a desktop, where the window draws, and where the arboard adapter is
held to the clipboard port's. Run it after a change to
`crates/editor-platform-winit`, to `crates/editor-platform-arboard`, to a
contract in `crates/editor-platform`, to the surface code of
`crates/editor-render-wgpu`, or to `render` in `crates/editor-ffi`. It uses
the image, the cache and the volume of `linux-ci`, and runs seven things
under Xvfb, a display that needs no screen and no person, failing if any
fails:

1. the window adapter's example, as `window-contract` runs it first;
2. `editor window-check --seconds 5`, with xdotool giving the window the
   focus and typing a sentence and a dead key into it;
3. the same with `--no-ime`;
4. the window that draws, as `window-contract` runs it second
   (`crates/editor-ffi/examples/window/`), on Mesa's software Vulkan
   driver, llvmpipe, and with `--require-picture`, which that task does
   not give. It is run twice: at scale 1, which is what Xvfb's display
   is at, and at scale 2. Each time, once it says it is ready, xdotool
   gives it `a`, Escape, Control-Shift-A, a press, a drag, a release, a
   turn of the wheel and a resize. The key with Control held must come
   off with no text: the X server gives it `A` (seen), and a key pressed
   with Control produced nothing to insert. The first run then ends with
   a change of scale, to 2, while the window is open ("The change of
   scale", below). Each run fails if the
   example fails (a frame whose glyphs are not drawn at 14 points times
   the window's scale; no frame presented; a frame whose picture was not
   read back from the surface and compared, whatever the reason; a
   picture more than 3 of 255 from the headless renderer's; a frame
   drawn that nothing asked for; a window left alone for a second with a
   frame not laid out for the size and scale it last said; no input), if
   any of those eight inputs did not come off the queue as the port
   documents it, the resize at the run's scale, and if no frame printed
   `at scale 1: 14 points are 14 pixels` in the first run and `at scale
   2: 14 points are 28 pixels` in the second.

   **The second run is what shows the window's scale reaching layout.**
   At scale 1 a layout that was told the scale and one that was not lay
   out alike, so the first run's line shows only that the fixture's 14
   points reach the real shaper and come back in the frame's fonts. For
   the second run winit is told the scale in the environment
   (`WINIT_X11_SCALE_FACTOR=2`, which its X11 back end takes in place of
   what the display says: seen at the pin). The window then says scale 2
   as it opens, the example's editor thread reads that off the resize it
   pulls from the queue and tells its layout, and the frame's fonts come
   back at 28 pixels. With the example made not to tell its layout the
   scale, the second run prints `14 points are 14 pixels` and fails with
   `frame 1 is laid out for a window at scale 2, where 14 points are 28
   pixels, and its glyphs are drawn at 14 pixels` (seen in the
   container, on 2026-11-14, and once before that on a desktop at scale
   2). The first run passed under that change for as long as it kept its
   scale of 1 to the end (seen); now that it ends with a change of scale
   it fails there too, on the frame laid out after the change, and the
   task stops before the second (seen). The pictures are read back and
   compared at scale 2 as at scale 1. The timeline ends each presented
   draw `its glyphs as subpixel masks, red first` in the first run, until
   its change of scale, and `its glyphs as plain masks` after that and
   in the second, on llvmpipe, which blends by a coverage for each
   channel; the task requires neither line.
   **What the second run is not**: a display at scale 2. It is winit
   that is told, the window is 800 by 600 pixels as it opens at either
   scale, and nothing shows how large 28 pixels look.

   **The change of scale.** The first run ends with the one change of
   scale the container can make, so that the adapter's line that takes
   winit's event for it apart is run on a real one (`App::window_event`
   in `crates/editor-platform-winit`, the `ScaleFactorChanged` arm: the
   event cannot be built in a test). winit's X11 back end reads the
   scale from the display's settings: `Xft/DPI` of XSETTINGS where a
   daemon serves them, else `Xft.dpi` of the X resources. For that run
   `xsettingsd`, which the image has for this alone, serves 96 dots an
   inch from before the window opens. Once the resize to 300 by 120 has
   come off the queue, and a second and a half more have passed so that
   the frame laid out for that resize is drawn and judged first, its
   file is rewritten to 192 and it is signalled to read it again. winit
   then sends the event, and the run requires
   what the port documents for it, a resize at the size last known and
   the new scale: `input: resized 300 by 120 at scale 2`. The example
   lays a frame out for it, which must say `14 points are 28 pixels` or
   the example fails. winit then asks the X server for the window at
   twice its size, and `input: resized 600 by 240 at scale 2` follows or
   does not (it followed in eighteen runs of twenty, and why not in the
   other two was not looked into): that line is not required. The
   required line came in all twenty. With the arm made to do nothing
   the run prints `input: resized 600 by 240 at scale 1`, the example
   passes, and the task fails with `the change of scale did not come off
   the queue as: input: resized 300 by 120 at scale 2` (seen).

   What was tried first, and does not work here: `xrdb -merge` of
   `Xft.dpi: 192` while the window is open. winit has a handler for a
   change of the root window's `RESOURCE_MANAGER`, but at the pin it
   asks the X server for property changes of its own windows and of the
   settings daemon's, not of the root (read); `xwininfo -root -events`
   listed no event of the core protocol that anybody wants of the root
   while the window was open, a property's change among them (seen);
   and no change of scale arrived, nor after `xrandr --dpi
   192` or `xrandr --fb 1000x700` following it, each of which the window
   answered as hidden, shown and damaged and no more (seen). `xrdb` and
   `xrandr` are not in the image.

   **What the change of scale is not**: a window moved between two
   displays. Here one display changes its settings, on X11. winit sends
   the same event for both, and the adapter's line is the same; what
   macOS sends around it, in which order the scale and the size come,
   and the antialiasing changing on a real display, are not seen;
5. the clipboard adapter's example, as `clipboard-contract` runs it: that
   display's clipboard held to the clipboard port's contract, in one
   process;
6. a text written to the clipboard by one process and read by another,
   while the first is still alive. One process cannot show this: on X11
   the text is served by the process that wrote it;
7. the editor on a file (since milestone 1): `editor --report` on a copy
   of `tests/window/session.txt`, with no toolchain, so no config, and
   xdotool typing `ihello `, `<Escape>`, `:w`, `<Return>`, `:q` and
   `<Return>`. The editor must exit 0 within 60 seconds, the copy must
   hold the bytes of `tests/window/session-expected`, and the report must
   count at least one frame. The report is printed; its figures are Xvfb's
   and llvmpipe's, not milestone figures. First run 2026-11-15 (Apple M5
   Max host, aarch64 container): all seven passed; the surface offered
   `immediate`, `mailbox`, `fifo` and `fifo-relaxed` and was configured
   with `fifo` at a frame latency of 1; 16 frames, `present - input`
   median 3704 µs, p99 51462 µs. The counters said no glyph was
   rasterised: why (whether the container's fonts give the editor's
   `monospace` anything) was not looked into, and the check does not ask
   for glyphs.

Its input is synthetic. It goes through the X server and the real window
library, so it shows the path a key and the pointer take on Linux, but
nobody typed it: it is not the keyboard check above, and its output says
so. Its clipboard is the container's own: nothing of this machine's is
read or written.

**It is the required confirmation of what the gate cannot hold.** The gate
opens no window, makes no surface and has no clipboard, so the gate being
green says nothing of any of them. Two things are confirmed here and
nowhere in the gate:

- that text written through the clipboard adapter is the text read back
  through it: parts 5 and 6;
- that the window draws a scene supplied by a fixture, and that input
  given to it arrives on the queue: part 4.

A change that touches the window, the surface or the clipboard is not done
until both `mise run ci` and this task exit 0, every part, on the tree that
is to land. Each of its checks was seen to fail once, in the container,
with the code changed for the run: the picture, with the surface drawn through a view that is not
sRGB (every pixel off, by 74 of 255); that a picture is compared at all,
with the surface configured without the use that lets its texture be
copied out, so that wgpu refuses the copy (`frame 1's picture could not
be read back: Validation Error`, for each frame), and with the surface
made to say its texture is not copied from (`frame 1's picture was not
compared, and this run requires it (--require-picture)`, for each
frame); the idle second, with a render loop
that marks its frame dirty after every draw (10 frames drawn, 0 asked for)
and with a window that asks for a redraw whenever it is asked for one
(270139 asked for); an input's line, with Escape named `Esc`; the
input itself, with nothing sent; the scale reaching layout, with the
example made not to tell its layout the scale (a run at scale 2 exits 1,
as quoted under part 4); that a frame was laid out at scale 2 at all,
with winit not told the scale in the second run (`no frame said it is
laid out at scale 2 and its 14 points are 28 pixels`); and the change of
scale, with the adapter's arm for it made to do nothing (`the change of
scale did not come off the queue as: input: resized 300 by 120 at scale
2`). Those two mutations of the idle second
were made again once the example judged each draw by what asked for it,
and each still fails the task: the first with `334 of the 336 draws were
asked for by nothing: the first is draw 2, which began 256.1 ms after
the window opened` and `336 draws were made and 5 were asked for`, each
such draw `for nothing that was asked` in the timeline; the second with
`the window asked to be drawn 273961 times while idle: more than 5 is a
timer`. Before the example failed a picture
that could not be read back, the first of those two mutations left this
task at exit 0 with three frames presented and no picture compared: a
journal entry shows that a present call returned, and only the
comparison shows that what was presented is the fixture.

Under Xvfb there is no clipboard manager, so a text is gone from the
clipboard when the process that wrote it ends. That is X11's rule and not
the adapter's, and part 6 keeps the writer alive for it. Xvfb's display
says no refresh rate either, so the window paces by the render loop's own
interval there, and pacing to a display's refresh is not seen.

It was run on 2026-11-14 (aarch64, Debian 13, Mesa 25.0.7): all six parts
passed. In part 4 the renderer was on llvmpipe through Vulkan, blending by
a coverage for each channel; three frames were presented, of 800 by 600
and, after the resize, of 300 by 120 twice; each was read back from the
surface and differed from the headless renderer's picture by 1 of 255 at
the worst; no frame was drawn in the idle second; and the eight inputs
came off the queue as documented. In the timeline the window said it was
shown and damaged before the first frame was published, so the first
draw was for both; the resize drew the frame shown on the new size and
then the frame laid out for it; and no draw was refused. It has not been
run on x86_64, and nothing here runs a Wayland compositor.

It was run again that day once the fixture's text was 14 points and the
example told its layout the window's scale: all six parts passed. Part 4
printed `window: frame 1 is laid out for 800 by 600 at scale 1: 14 points
are 14 pixels` and, after the resize, `window: frame 2 is laid out for 300
by 120 at scale 1: 14 points are 14 pixels`; three frames were presented
and each was read back and differed from the headless renderer's picture
by 1 of 255 at the worst; each draw ended `presented, its glyphs as
subpixel masks, red first`; and no frame was drawn in the idle second.
And once more with the fifth check: all six parts passed, with the same
lines and `window: left alone 2 times, and each time the window showed
what was laid out for it`. In those runs part 4 ran the window once, at
scale 1.

It was run again that day with part 4's second run, at scale 2: all six
parts passed. The second run printed `input: resized 800 by 600 at scale
2`, `window: frame 1 is laid out for 800 by 600 at scale 2: 14 points are
28 pixels` and, after the resize, `window: frame 2 is laid out for 300 by
120 at scale 2: 14 points are 28 pixels`; three frames were presented and
each was read back and differed from the headless renderer's picture by 1
of 255 at the worst; each draw ended `presented, its glyphs as plain
masks`; no frame was drawn in the idle second; the window was left alone
twice and showed what was laid out for it; and the eight inputs came off
the queue as in the first run, the resize at scale 2. The container has
one display, at scale 1: the scale of 2 is what winit was told.

And again that day, six times, with the change of scale at the end of
part 4's first run: all six parts passed each time. A second and a half
after `input: resized 300 by 120 at scale 1` the first run printed
`input: resized 300 by 120 at scale 2`, `window: frame 3 is laid out for
300 by 120 at scale 2: 14 points are 28 pixels`, `input: resized 600 by
240 at scale 2` and `window: frame 4 is laid out for 600 by 240 at scale
2: 14 points are 28 pixels`. Five frames were presented: three at scale
1, in subpixel masks, as before; then the frame laid out at scale 1 on
300 by 120 at scale 2, which is the one draw a frame of the old scale
gets on the new one; then the frame laid out for 600 by 240 at scale 2;
those two in plain masks. Each picture was compared, the worst by 1 of
255, and the window was left alone three times and showed what was laid
out for it each time. Before that the scale was changed fourteen times
as soon as the resize had arrived, without the wait, seven of them with
no pointer input: the required line came every time, and the
window grew to 600 by 240 in twelve and stayed 300 by 120 at scale 2 in
two, where the run passed as well.

## The clipboard, on demand

```sh
mise run clipboard-contract
```

On Linux its two halves are parts 5 and 6 of `linux-window`, above, which
run in the container. It has not been run on a desktop.

**It writes the clipboard of the desktop it is started from.** It holds the
system clipboard (`SystemClipboard` in `crates/editor-platform-arboard`) to
the clipboard port's contract (`crates/editor-platform`,
`clipboard::contract`), so it is not part of the gate, which only builds it:
a real clipboard is the desktop's, and the gate leaves the machine as it
found it. It is the example of `crates/editor-platform-arboard`
(`examples/clipboard.rs`), run with `contract`.

What it does to the clipboard: it keeps the text it finds there, writes
four texts of its own, and puts the text it found back. **Only text is put
back.** An image, a file or anything else that was on the clipboard is
lost, and a clipboard that held no text is left holding the contract's
last text, `a later text`.

It prints one line for each of the contract's four properties, each
beginning `clipboard-contract: holds:`, then `the text found on the
clipboard was put back` and `the system clipboard keeps the clipboard
port's contract`, with exit status 0. A property that fails is printed
with `FAILS` and the exit status is 1; so is a clipboard that could not be
opened, with the reason. The contract does not ask whether the empty text
reads back as the empty text or as no text.

## The renderer on a real GPU, on demand

```sh
mise run render-gpu
```

The gate runs the wgpu renderer on wgpu's no-op back end only, which
checks its calls and draws nothing ([`the-gate.md`](the-gate.md)). This is
where the picture it draws is checked. What it finds depends on this
machine's GPU and its driver, and a machine with no GPU has nothing to run
it on, so it is not part of the gate, which only builds it. It opens no
window: it draws to a texture and reads it back.

It is the example `gpu` of `crates/editor-render-wgpu`
(`examples/gpu.rs`). It does three things, and its exit status is whether
the first two held:

1. holds a renderer on this machine's adapter to the renderer port's
   contract (`crates/editor-render`, `contract`);
2. draws the fixture frame of real text, reads it back and compares it
   with what the CPU compositor draws: no channel of any pixel may differ
   by more than 3 of 255. In subpixel masks it is compared with the
   reference image `tests/render/frame.png`; in plain masks, as a display
   of two physical pixels to a logical one gets them, with the headless
   adapter's picture of the same frame drawn the same way. An adapter
   that cannot blend by a coverage for each channel draws only the
   second. Then the same frame at the macOS weight
   (`Settings::core_text()`), in plain masks and, where the adapter can,
   in subpixel masks, each against the headless adapter's picture drawn
   with the same settings: the contrast reaches the shader and the
   dilation the atlas. The fixture has no colour glyph, so a colour image is drawn by
   no GPU here: that path of the shader is validated in the gate and has
   never been seen;
3. prints how long a first frame, a frame with a row edited and a frame
   that differs only in its cursor took, with the rows each built. The
   times are of one run of a debug build: nothing is asserted of them and
   they are no measurement.

Run it after a change to the shader, the wgpu device, the painter or the
blend, and when the pin of wgpu moves. Do not loosen the 3 to make it
pass: a difference past it is a finding.

It was run on 2026-11-14 on macOS (aarch64): Metal on an Apple M5 Max,
blending by a coverage for each channel; all 9 properties of the contract
held; 42 of the frame's 24576 pixels differed from the reference image,
and 14 from the headless adapter's picture in plain masks, the worst by 1
of 255 in each.

It was run again on 2026-11-14 on the same machine (macOS 27.2, Metal on
the Apple M5 Max), with the macOS weight's comparisons: exit status 0;
all 9 properties held; 42 pixels differed from the reference image and 14
from the plain masks, as before; at the macOS weight, 35 differed in plain
masks and 64 in subpixel masks, the worst by 1 of 255 in each. With the
contrast left out of the CPU's side only (a change made for the run and
undone), the macOS weight's comparisons failed, the worst by 5: so the
check sees the shader's contrast.

## The renderer on Linux, on demand

```sh
mise run linux-render
```

The same example, in the container of `linux-ci`, on Mesa's software
Vulkan driver, llvmpipe: a real adapter that needs no GPU. It needs
Docker. The image installs Mesa's Vulkan drivers and the Vulkan loader for
this task alone (`tools/linux/Dockerfile`); they are in the image
`linux-ci` uses too, and the gate there, which asks for no adapter, runs
the same with them.

It was run on 2026-11-14 (aarch64, Debian 13, Mesa 25.0.7): llvmpipe
through Vulkan, blending by a coverage for each channel; all 9 properties
held; 247 pixels differed from the reference image, and 168 from the
headless adapter's picture in plain masks, the worst by 1 of 255 in each.
It has not been run on x86_64.

It was run again on 2026-11-14 (aarch64, on an Apple M5 Max host), with the
macOS weight's comparisons: exit status 0; llvmpipe (LLVM 19.1.7) through
Vulkan; all 9 properties held; 247 and 168 pixels differed, as before; at
the macOS weight, 246 differed in plain masks and 394 in subpixel masks,
the worst by 1 of 255 in each.

## The reference image, on demand

```sh
mise run render-reference
```

This writes `tests/render/frame.png`, the picture the gate compares the
headless renderer's with, by running the example `reference` of
`crates/editor-render-wgpu`. It writes a file of the repository, which no
gate may do, so the gate only builds it. `tests/render/README.md` says
what the image shows and when to make it again.

```sh
mise run theme-references
```

This writes four files, the pictures the gate compares the themes' with:
`tests/render/themes/default.png`, the built-in theme's, by running
`ffi-test theme-pictures … --write`; and
`packages/shipped-themes/tests/render/solarized-dark.png`,
`solarized-light.png` and `fairy-floss.png`, the shipped themes', by
running their package's linked test with `--write` in the package's
directory. It writes files of the repository, so it is never part of the
gate. `tests/render/themes/README.md` and
`packages/shipped-themes/tests/render/README.md` say what the images show
and when to make them again.

## The Core Text reference, on demand

```sh
mise run coretext-reference
```

This writes `tests/coretext/sentence.png`: the sentence `the window draws
this` drawn by Core Text from the fixture font Noto Sans Mono at 14 pt on
a bitmap of scale 2, black on white, with font smoothing on. It is the
macOS target the renderer's weight is fitted to and held to
(`crates/editor-render-wgpu/src/weight_tests.rs`). It runs
`tools/coretext/capture.swift` with the system's `swift`, so it needs
macOS. It writes a file of the repository, which no gate may do, so it is
not in the gate, and nothing in the gate runs Swift.

Run it on a new major version of macOS, or when the fixture font changes.
`tests/coretext/README.md` records how the file was last captured. If a
new capture no longer matches the renderer's weight, the weight is fitted
again.

## The editor on a file, on demand

`mise run edit -- <file>` (`lean/Editor/Window/Real.lean`) opens the
editor on a file, in a window, to use, through the app's launcher
(`target/release/leanmacs --default packages/.lake/build/bin/editor`): it
starts the newest per-user build of your package set under
`~/.local/share/leanmacs/editors/<core>/` when there is one for the
checkout's core, and otherwise the editor `mise run lean` links from the
default package set, `packages/.lake/build/bin/editor`
(`docs/design/packages.md`, "User package sets"). The gate runs the same wiring on
the library's scripted platform (`ffi-test window-host`), and `mise run
linux-window` runs it on a real window under Xvfb with xdotool typing
(its seventh part).

## Milestone 1, measured

Milestone 1's figures: key press to frame submitted (median and 99th
percentile), idle CPU, memory at startup, memory after opening a 10 MiB
file, and scrolling through it. Each figure goes in the phase body with
the command that gave it, and with what it is: headless, or a window's.

**Headless: `mise run milestone-bench`**
(`tools/milestone-bench.sh`), on a quiet machine, twice. It runs five
scripts of `editor headless --render` under `/usr/bin/time -l`, and prints
the machine first. Every figure it gives is labelled "headless: cell
shaper, CPU renderer, no glyphs": what Lean, layout and the loop cost, and
not what a window costs.

| Figure | Script | Line it prints |
|---|---|---|
| Memory at startup | `start`: a frame of 1280 by 800, no file | `start: maximum resident set …`, `start: peak memory footprint …` |
| Memory after opening a 10 MiB file | `open`: `:e` on a generated file of 201,650 lines of 52 bytes (10,485,800 bytes), then `join` | `open: maximum resident set …`, `open: peak memory footprint …` |
| Scrolling through it | `scroll`: 300 `C-f`, each paced by `idle 0`, then `G` | its second `journal` line (the 300 frames' `present - input` and rows rebuilt) and its third (`G`); `scroll: real …` |
| Key press to frame submitted | `type`: 200 `l` and `h` in a 640 by 480 view of a small file, each paced by `idle 0` | its second `journal` line |
| Idle CPU | `idle-30000` against `idle-0`: the same session with `idle 30000` and `idle 0` | the difference of their `user` + `sys`, and `idle 30000: 0 frames drawn, 0 frames submitted` |

`idle 0` paces a key: it waits until the render loop has drawn what the key
asked for and is at rest, so that no key's frame is replaced in the
mailbox before it is drawn.

**The session journal's cost** (session-restore phase 1). Then
`milestone-bench` runs `type-insert`: 200 characters typed in insert state
at the end of the 10 MiB file and of the small file, each paced by
`idle 0`, once with `--state` and once without. Each prints its
`journal` lines and its `real`, `user` and `sys` times, and a run with a
state directory the bytes left under its journals. The expectation, never
gating: the median `present - input` with a state directory within 5% of
the run without. On an Apple M5 Max, macOS 27.2.1, headless:

| Run | Median present - input | p99 | Journals left |
|---|---|---|---|
| `type-insert-ten-state` | 17242 µs | 18310 µs | 10,496,179 bytes |
| `type-insert-ten-none` | 17189 µs | 18268 µs | |
| `type-insert-small-state` | 17423 µs | 18307 µs | 9,969 bytes |
| `type-insert-small-none` | 17434 µs | 18250 µs | |

**`mise run journal-bench`** (`config-test bench-journal`,
`lean/ConfigTest/Bench.lean`) times the editor thread's share alone: the
reconciler and the hand-off of its orders to the library's file service
for 10,000 one-character inserts into a file buffer of 4 KiB, 1 MiB and
10 MiB, at its start, middle and end, each row
`journal_order/<size>/<position>` with its median, 99th percentile and
maximum in µs. The expectation is under 20 µs a key at 10 MiB. On the same
machine every row's median was 3.1 to 3.5 µs and its 99th percentile 4.4
to 6.9 µs (`journal_order/10MiB/end`: 3.5 / 4.4 / 25.8). perf-suite is to
adopt the rows once its harness exists.

`mise run edit -- --report <file>` prints a window's figures from the
frame journal when the window closes ("The present mode, measured on a
window", below).

## The present mode, measured on a window

The decision was taken by reading: `Fifo` at a frame latency of 1 on
every platform ([`rendering-prior-art.md`](../design/rendering-prior-art.md),
"Present mode and pacing"). No figure from a window on a display has
been taken yet; Xvfb has no display to pace against. The window mode has
what a measurement needs:

- a surface on the window, configured from what `present::choose`
  (`crates/editor-render-wgpu`) gives for the modes the surface offers
  (a surface does not report its range of frame latency: the one asked
  for is held to it by wgpu);
- the render loop running on its thread, on the clock that stamps window
  input (`editor-ffi`'s), so that an entry's input time and its present
  time are on one clock;
- `--present-mode fifo|fifo-relaxed|immediate|mailbox` and
  `--frame-latency <n>`, flags of the window mode for one run, not
  settings, each on its own: the renderer gives the mode asked when the
  surface offers it, and the decision's otherwise or when none is asked,
  and the latency asked, or the decision's when none is asked, held to the
  range offered (`present::choose` in `editor-render-wgpu`);
- frames published from Lean reaching the window, stamped with the key
  they answer, so that a key typed draws a frame;
- `--report`, which prints to stderr once the window has closed what the
  surface offered, only what was asked (`asked a frame latency of 2` for
  `--frame-latency 2` alone) and what was configured, the counters,
  each journal entry's present time with its `present - input`, their
  median, 99th percentile (nearest rank) and largest, and the longest
  stretch with no frame.

The modes a report says a surface offered are held against the table in
`rendering-prior-art.md`, of which the Vulkan row has been seen on a
surface (llvmpipe, under Xvfb) and the others only read in wgpu's source.
If figures from a window favour another presentation, the decision in
`rendering-prior-art.md` and `present::PREFERRED` change in the same
commit.
