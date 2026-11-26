# The Lean program

How the executable is built and started, how config is loaded and reloaded,
what the editor API looks like, and where state lives.

Two throwaway prototypes stand behind this document. The first (commit
`4e57f01`) embedded Lean in a Rust process and proved runtime elaboration
and live reload. The second (the spike, uncommitted, notes in
`research_notes/lean-host-spike.md`) turned it round: a Lean executable
linking a Rust static library. The design below is the second arrangement.

## Build

Lake builds the executable. The Rust library is a Lake target that runs
`cargo build`, and Lake relinks only when the archive's contents change.

- **The editor is built from a package set**, not as a target of the
  core: a Lake package whose `require`s are the core and the packages. The
  core's lakefile defines the build as a facet, and in `lean/`
  `lake -d ../packages build :editor` writes the executable's root module
  from the default set's packages, builds it and links
  `packages/.lake/build/bin/editor`
  ([packages.md](packages.md), "The package set and its build"). The test
  executables (`ffi-test`, `config-test`, `contract-test`, `model-test`)
  are still targets of the core, under `lean/.lake/build/bin`.
- **The executable's symbols are exported** (`-rdynamic`, which is what
  `supportInterpreter := true` gives a `lean_exe`, and what the test
  executables that interpret config set), so that interpreted config can
  call compiled code. Without it the interpreter aborts on the first
  missing symbol.
- **A small glue file** in C holds what neither language can express:
  one-line wrappers where a Lean `@[extern]` signature needs `lean.h`
  (which is mostly inline functions Rust cannot call), and the entry point.
  The spike's was 133 lines.
- **The system compiler compiles the glue and links the executables**, on
  macOS and on Linux (`LEAN_CC=/usr/bin/cc`, set by the `lean` task). The
  clang bundled with Lean has no `pthread.h` on either, and on macOS the
  toolchain ships no link stub for any Apple framework, so its linker finds
  none of those the Rust library needs. It links them when it is given
  stubs it can read, and it cannot read the stubs of the SDK this build
  uses ("A link on the user's machine, measured", below). With `LEAN_CC`
  set Lake no longer adds the toolchain's library directory to the link, so
  the lakefile does. lean-fmt and the model tests are still built by the
  bundled compiler.

The build runs on macOS and on Linux, and the gate passes on both
(`mise run linux-ci` runs it in a container;
`docs/dev-practices/on-demand-checks.md`). Four things differ
by platform, and each has a case for those two and fails the build with a
reason anywhere else:

| | macOS | Linux |
|---|---|---|
| The entry point in place of `main` | `-Wl,-e,_editor_entry`: the loader calls `editor_entry` | `-Wl,--wrap=main`: `-e` would replace `_start` and skip the C library's start-up, so the linker renames instead. The start-up code's `main` is the glue's `__wrap_main`, which calls `editor_entry`, and Lean's `main` is `__real_main`. GNU ld and lld both have `--wrap` |
| Is this the main thread? | `pthread_main_np` | The thread whose id is the process's: `getpid() == gettid()` (glibc 2.30 and later) |
| A thread's stack size, for the check that Lean's threads have the editor's stack | `pthread_get_stacksize_np` | `pthread_getattr_np` and `pthread_attr_getstacksize`, which need `_GNU_SOURCE` |
| What the link names beyond the objects | The frameworks winit needs: ApplicationServices, CoreGraphics, CoreVideo, Carbon, CoreFoundation, AppKit, Foundation, with `-liconv -lobjc` | Nothing: winit loads the display's libraries when it runs |

On Linux the system compiler is gcc (run with gcc 14.2.0, GNU ld 2.44 and
glibc 2.41, on Debian 13, aarch64). Lake's own link line there takes
`libc++` and `libc++abi` statically from the toolchain, so the executable
needs only `libc`, `libm` and `libgcc_s` at run time, and `libstdc++` is not
involved. Not run: x86_64, and a desktop session.

**Windows has not been attempted**, and nothing here was run there. The
entry point, the main-thread check and the stack readout each need a third
case. Lean's Windows toolchain is MinGW-based, so the Rust archive would have
to be built for a `-windows-gnu` target.

**The C++ library on macOS is the system's, whichever compiler links.** It
was an open question whether linking with the system compiler, and so
against the system `libc++` in place of one bundled with Lean, could go
wrong. There is no bundled one to differ from. What Lean's toolchain ships
is a link-time stand-in whose install name is `/usr/lib/libc++.dylib`, and
`libleanshared.dylib`, which `lean` itself runs on, names that path too. An
executable linked by Lean's own clang and lld (`model-test`) and one linked
by `/usr/bin/cc` (`contract-test`) load the same `/usr/lib/libc++.1.dylib`,
one file with one UUID. So `LEAN_CC=/usr/bin/cc` changes the linker, not the
library. Checked on the tree as built: `model-test` linked both ways passes
with the same count; the gate passes; the soak benchmark's resident memory
is flat from 100 reloads to 500; and `leaks --atExit` on `contract-test` and
on the headless mode finds only what Lean's runtime allocated as its modules
initialise (big-number constants, three mutexes, regions read from `.olean`
files), nothing allocated by the glue or the Rust library, and the same
count for a script a hundred times as long.

**The app bundle is a facet of the set too** (`editorApp`, which nothing
builds by default; `mise run app` builds it from the default set, at
`packages/.lake/build/Leanmacs.app`). It copies the set's executable and
everything a user's package-set build needs into `Leanmacs.app` ("The app
ships the toolchain", below), writes `Info.plist`, with
the version from `lean/app/version` as `CFBundleShortVersionString`, the
build ID as `CFBundleVersion`, the commit as `LeanmacsCommit` and the
core's tag, `nightly-<build ID>`, as `LeanmacsCoreTag`, keys of the app's
own, and the icon, made from the checked-in
artwork `lean/app/Leanmacs.png`, and signs the whole bundle ad-hoc, last.
The build ID and the commit come from the environment,
`LEANMACS_BUILD_ID` and `LEANMACS_COMMIT`, which `mise run app` sets from
HEAD and CI from its run (`crates/editor-release`); a build without either,
or with one malformed, is refused, naming the variable. `editor --version`
reads the three keys back (`lean/Editor/Version.lean`). Lake's trace of
its inputs, the plist's text among them, makes it rebuild only when one
changed, so a new commit rebuilds it. It builds on macOS on
arm64 only. How to build it, what it holds and why it is signed again are
in [building.md](../dev-practices/building.md), "The app bundle".

### The app ships the toolchain

A user's package set is built by the editor itself
([packages.md](packages.md), "User package sets"), so the app carries
everything that build needs, and a set of pure-Lean packages builds from
the app alone, with no Lean, compiler or Cargo on the machine (decided
2026-11-20: the app ships the Lean toolchain only; no SDK, no C library
headers and no Cargo). Under `Contents/Resources`:

```
editor.core, editor.oleans, editor.build   the records (below)
lean/toolchain/                            the Lean toolchain, whole, but mise's exposed/
lean/lean/                                 the core: lakefile.lean, lean-toolchain, lake-manifest.json,
                                           ffi/glue.c, the sources of the Editor library and FilesApi,
                                           and their .lake/build output with every trace and hash
lean/set/                                  the default set: lakefile.toml, lake-manifest.json, lean-toolchain
lean/set/shipped-themes/, lean/set/compile/  each default package: its lakefile, sources and build output
lean/target/release/libeditor_rust.a       the core's Rust archive
lean/target/editor-rust/core/native-static-libs  the system libraries it needs
lean/link-stubs/                           macOS: the system libraries' link stubs
```

- **Where things are follows from the lakefiles.** The set's lakefile
  names `../lean` and each package's `../../lean`, which both reach
  `lean/lean`, so no lakefile is rewritten; and `repositoryRoot`, the
  core's directory's parent, is `lean/`, so a user's set outside it
  reuses the archive in `lean/target` with no Cargo (`prebuiltRust`).
- **What ships is Lake's list.** `lake -d <set> query :editorShipped`
  builds and lists every module of the core's `Editor` library and its
  interface library `FilesApi`, which a package may import, and of each other library of the
  set's packages but its tests, with the files Lake wrote for each, the
  lakefiles and the core's glue; the `stage-bundle` binary
  (`editor_release::bundle`) copies the list and decides nothing. Each package's modules ship once, in that package's
  own build directory.
- **A build from the bundle compiles none of it.** Lake decides "up to
  date" by trace hashes, never by modification time; a module's trace mixes
  its source's hash, its imports', its options, the platform and Lean's
  githash, and no path. So the core's and the packages' outputs, built in
  CI with the system compiler and copied with their `.trace` and `.hash`
  files, are up to date at another path under the bundled `clang`. Lake
  writes a dependency's elaborated lakefile into the root workspace
  (`<config>/.lake/config`), so a user's build writes only into the config
  directory and the data directory, never into the bundle.
- **The bundle's records.** `editor.oleans` names the `.olean`
  directories, relative to `Contents/Resources`
  (`lean/Editor/ModuleLookup.lean`, "The bundle's record").
  `editor.build` is the executable's `.build` record without `LEAN_CC`, so
  a build the app runs keeps `MACOSX_DEPLOYMENT_TARGET` and compiles with
  the bundled `clang` (`lean/Editor/PackageSet/Running.lean`).
- **The toolchain a build runs is the running editor's,** whatever is on
  the `PATH` or in the environment. The job runs `<sysroot>/bin/lake` by
  absolute path, and Lake finds `lean` and `clang` beside itself; the job
  removes `LEAN_CC`, `LEAN_SYSROOT`, `LEAN`, `LEAN_PATH`, `CC` and the rest
  of `clearedVariables` before setting the build record
  (`lean/Editor/PackageSet/Build.lean`); and the core's lakefile asks Lake
  for its toolchain (`Lake.findInstall?`), never the `PATH`
  (`leanSystemLibDir`, `editorLinkArgs`).
- **The link uses the bundled `clang` and `ld64.lld` with link stubs.**
  The toolchain ships no stub of any Apple framework, so on macOS, when
  Lake links with the toolchain's own compiler (no `LEAN_CC`), the
  editor's link names the system's libraries from
  `Contents/Resources/lean/link-stubs`: `-F` and `-L` the directory, a
  `-framework` or `-l` for each stub, and `-Wl,-platform_version,macos,
  <minos>,<sdk>` from its `platform-version` (`linkAsEditor`,
  `stubLinkArgs`). The `stage-bundle` binary writes them from the shipped
  editor (`editor_release::stubs`, as the `link-stubs` binary does), as
  phase 1 proved ("A link on the user's machine, measured"). With `LEAN_CC` set, a checkout's link, the
  archive's `native-static-libs` line is passed as before. The stubs hold
  only what the shipped editor imports, and the toolchain has no C library
  headers, so a package's C that calls another system function or
  includes `<stdio.h>` needs the user's own tooling
  ([packages.md](packages.md), "Who can build it").
- **Fetching a git or Reservoir package uses the system `git`**, which the
  app does not ship (decided 2026-11-18); a missing one is reported
  ([packages.md](packages.md), "The build, as a job").

There is no hand-written Lean start-up sequence and no scraping of
generated symbol names, which the first prototype needed. What can break on
a Lean upgrade is the `@[extern]` calling convention, the Lake build API,
and the compiler and entry-point workarounds above. The package-set build
leans on more of that API than a `lean_exe` did: package and module facets
defined in a required package's lakefile and run on a TOML root, a library
value and a module made in a facet for a root no lakefile declares, a
module's link information (`linkInfoExport`), `buildLeanExeSync`, a
package's `depConfigs`, and `lake query` over a facet. Symbol names carry
the Lake package's name, so renaming the core's package changes every
symbol; nothing outside Lean's generated code names one.

### A link on the user's machine, measured

**The decision is toolchain-only linking** (2026-11-18): an `editor` is
linked on the user's machine from pieces the app ships, with the `clang`
and `ld64.lld` the Lean toolchain bundles, and the Xcode command line tools
are not required. It is the link that compiling a package into a rebuilt
executable needs on the user's machine ("Third-party packages", under
"Open questions"), and it was in doubt because the toolchain ships no
macOS SDK.

It was measured on 2026-11-18, on an Apple M5 Max, macOS 27.2.1, with Lean
4.35.0 (its clang and lld are 23.1.0), on a machine that has Xcode 27.2 and
the command line tools, by a check run by hand. The check staged the
pieces below in a temporary directory, by copy; built a trivial package
and linked an `editor` from it with the staged `lake`, inside a sandbox
where the tools could not be reached; signed the result with `codesign
--force -s -`; and ran it. When this was measured the package brought two
modules of its own: its one module, `UserLinkFixture`, with its one
command; and a root written by hand, `Main`, 78 lines that copied the body
of the shipped headless host, standing in for the root the package-set
build was to generate. The figures below are of that root. **That root is
gone: a relinked editor's root is now generated**, as the editor's own is
([packages.md](packages.md), "The generated root"). The build that
generates a root is a facet of the core's lakefile (`editorRoot`, which
writes a set's root and links nothing), and a staged core of prebuilt
pieces behind a lakefile with no target cannot carry it, so the check
later asked the checkout for its set's root and staged that file beside
the package's sources. The generator on the user's machine, where there
is no checkout to ask, came with the packages roadmap's phase 9: the app
ships the core built, whose lakefile supplies the facets, and links a
user's set with the same stubs ("The app ships the toolchain", above;
`dmg-check` builds the default set from the packed image alone). The
check read the pieces from the default set's editor
(`packages/.lake/build/bin/editor` and its `editor.rsp`), and the object
it left out was that editor's generated root's, where it was `Main`'s. It
asserted that the relinked editor printed exactly the standing headless
fixture's `expected` but for the package's own command, which each of the
two lines that list the commands named once, and that the package's
command ran and said its message in the echo area. MB are 10⁶ bytes of
apparent size.

**`libSystem`: the macOS SDK's stubs are not needed.** The linker's own
report of the files it opened (`-dependency_info`) names
`<stage>/toolchain/lib/libc/libSystem.tbd`, the stub the Lean toolchain
ships, and `<stage>/toolchain/lib/libc/libc++.dylib`, its stand-in for the
C++ library, and no other file for either. No symbol the editor needs was
missing from that stub, so none is generated for it.

**The frameworks, `libobjc` and `libiconv` have no stub in the toolchain,
so stubs are written from the built editor.** The app is to ship them;
nothing but the check makes them yet. The `link-stubs` binary
(`crates/editor-release-std`, `editor_release::stubs`) reads the built
`editor` (`otool -L`, `nm -m -u`) and writes one text stub (`.tbd`,
version 4) for each library it loads other than `libSystem` and `libc++`:
the library's install name and versions, and only the symbols the editor
imports from it. That is 14 stubs, 8,681 bytes with the file below: the ten
frameworks the editor's link names; `ColorSync` and `CoreServices`, which
the built editor loads though its link does not name them, because the
system linker bound `CGDisplayCreateUUIDFromDisplayID` to the one and the
`FSEvents` functions to the other; and the two libraries. The relink names
all 14. No file of the SDK is copied.
It also writes the minimum macOS and the SDK version the built editor
records (`platform-version`), which the relink passes on with
`-platform_version`. With no SDK the linker records the minimum macOS as
the SDK version, 26.0 where the built editor has 27.2, and AppKit chooses
behaviour by that version. With them passed on, the relinked editor
records `minos 26.0, sdk 27.2`, as the built one does.

The staged pieces the relink used:

| Piece | Where it comes from | Files | Size |
|---|---|---|---|
| `toolchain/` | The Lean toolchain, whole (`lean --print-prefix`), less `exposed/`, which mise adds | 17,901 | 3,131.0 MB |
| of it, what the linker opened | Lean's seven static libraries, `libgmp`, `libuv`, `libssl`, `libcrypto`, compiler-rt, `libSystem.tbd`, `libc++.dylib` | 14 | 274.6 MB |
| `core/lib/` | The `.olean` file of each module the built editor's link names, less its root (`lean/.lake/build/lib/lean`) | 217 | 163.7 MB |
| `core/obj/` | The object of each of those modules, `.c.o.export` (`lean/.lake/build/ir`) | 217 | 17.3 MB |
| `core/glue.o` | The glue object, as `mise run lean` compiled it | 1 | 0.1 MB |
| `core/libeditor_ffi.a`, now `core/libeditor_rust.a` | The Rust archive (`target/release`): as measured, `editor-ffi`'s; now the crate the package-set build generates for the default set, which holds no package crate, so the core's ([packages.md](packages.md), "Rust in a package"). Beside it now `core/native-static-libs`, the system libraries rustc printed for it, which the link passes when it links against an SDK | 1 | 82.0 MB |
| `core/lakefile.toml`, `core/lake-manifest.json` | The check's own: they make `core/` a Lake package with no target | 2 | 772 bytes |
| `stubs/` | The link stubs written from the built `editor` (now by the `link-stubs` binary): 14 stubs and `platform-version` | 15 | 8,681 bytes |
| `package/` | As measured, the fixture package: `lakefile.lean`, `Main.lean`, `UserLinkFixture.lean`. With the generated root, its sources, its entry module, its lakefile and the generated `EditorSetRoot.lean`: 4 files, 9,183 bytes | 3 | 10,028 bytes |

The rule for the editor's modules is the built editor's own link line
(`packages/.lake/build/bin/editor.rsp`; `lean/.lake/build/bin/editor.rsp`
when this was measured): every object it names, less its root's, because
the package brings the root and two `main` symbols cannot link. Since the
shipped themes became a default package (2026-11-19) that link names
objects of two Lake packages, the core's and `shipped-themes`', each built
in its own directory. The check stages each from the package the record
beside the built editor says built it (`editor.oleans`), all into
`core/`, which so stands for the prebuilt pieces, the core and the default
packages together: 228 `.olean` files (165.4 MB) and 228 objects (17.9 MB)
on that date, where the table above has 217. Since the compile mode became
the second default package, the same day, the link names objects of three
Lake packages, and the stage holds 229 of each (165.5 MB and 17.9 MB): the
compile mode's five modules were the core's before, and its entry module
is the one more. The relinked editor's config base is its set's, `Editor`
and then the entry modules of the default packages and of the fixture
package, and it has no record, so the check's run step gives it two
`.olean` directories joined with `:`, the staged pieces' and the one the
package's build wrote. The app ships the default packages as prebuilt
pieces of their own since phase 9, each in its own build directory.
The toolchain is staged whole, so the set is sufficient and not shown
minimal: what `lake`, `lean` and `clang` read of it was not measured, only
what the linker opened.

Times are medians of five runs, in seconds of wall clock, the first column
inside the sandbox. The package build elaborates the one module,
`UserLinkFixture`. The whole build and link elaborates that and the
hand-written root `Main`, compiles the C of both to objects, and links; so
it includes compiling a root, as the build of the generated one that
replaced it does (which also elaborates the package's entry module; on
2026-11-19, with the generated root, the package build was 0.70 s):

| | Bundled `clang` and `ld64.lld` | `/usr/bin/cc`, with the SDK (`--linker system`) |
|---|---|---|
| The package build, from a clean build directory (`lake build UserLinkFixture`) | 0.59 | 0.58 |
| The whole build and link, from a clean one (`lake build editor`) | 1.88 | 1.56 |
| The link alone (the link line Lake ran, run again) | 0.50 | 0.25 |
| The signing (`codesign --force -s -`) | 0.29 | 0.14 |
| The relinked `editor` | 230.5 MB | 230.8 MB |

The built `editor` was 232.2 MB. The link line, as Lake ran it, with
`<package>` for `<stage>/package`, the fixture's copy:

```
<stage>/toolchain/bin/clang -o <package>/.lake/build/bin/editor @<package>/.lake/build/bin/editor.rsp
```

and its response file, with the 217 objects under `<stage>/core/obj` cut:

```
<package>/.lake/build/ir/Main.c.o.export <package>/.lake/build/ir/UserLinkFixture.c.o.export
-rdynamic <stage>/core/obj/**/*.c.o.export <stage>/core/glue.o <stage>/core/libeditor_ffi.a
-L <stage>/toolchain/lib -Wl,-e,_editor_entry -F <stage>/stubs -L <stage>/stubs
-framework AppKit -framework ApplicationServices -framework Carbon -framework ColorSync
-framework CoreFoundation -framework CoreGraphics -framework CoreServices -framework CoreText
-framework CoreVideo -framework Foundation -framework Metal -framework QuartzCore -liconv -lobjc
-Wl,-platform_version,macos,26.0,27.2 -Wl,-dependency_info,<package>/.lake/build/link.dependency-info
-L <stage>/toolchain/lib/lean --sysroot <stage>/toolchain -L <stage>/toolchain/lib
-L <stage>/toolchain/lib/libc -fuse-ld=lld -lleancpp -lInit -lStd -lLean -lleanrt -lc++ -lLake
-lLeanExport -lgmp -luv -lssl -lcrypto -Wl,-dead_strip
```

(As measured; the archive is now `<stage>/core/libeditor_rust.a`.)

The first two objects are the package's own modules, and `-rdynamic` is
from `supportInterpreter`. From the editor's objects to `-dependency_info`
it is the package's `moreLinkArgs`, and the rest is what Lake adds for
the bundled compiler.

**How the tools were made unreachable.** The machine has Xcode and the
command line tools, so their absence is enforced, in three layers:

- **A sandbox** round the package build and the link (`sandbox-exec`
  with a profile of the check's). It runs no program
  outside the stage, and lets nothing be read under `/Applications`,
  `/Library/Developer`, `/opt`, `/usr/local` or `/Users`: Xcode and both
  SDKs, the real toolchain, Cargo and the repository. The base system
  stays readable, as on a Mac that never had the tools.
- **An empty environment** (`env -i`) but for `PATH`, `HOME` and `TMPDIR`
  inside the temporary directory, and `MACOSX_DEPLOYMENT_TARGET`: no
  `SDKROOT`, `DEVELOPER_DIR`, `LEAN_CC` or `LEAN_PATH`.
- **Decoys first on the `PATH`**, named `xcrun`, `xcodebuild`,
  `xcode-select`, `cc`, `gcc`, `clang++`, `ld`, `ar` and `git`, each of
  which records that it was run and fails. On a Mac without the tools
  `/usr/bin/xcrun`, `/usr/bin/clang` and `/usr/bin/git` are shims that open
  the install prompt, so a build that reaches for one is a defect.

The check probes the sandbox before it builds anything, under the same
profile and environment. Each of these was refused with `Operation not
permitted`: running `/usr/bin/xcrun --show-sdk-path`,
`/usr/bin/clang --version`, `/usr/bin/ld -v`, `/usr/bin/cc --version` and
`/usr/bin/git --version`; reading the SDK's `usr/lib/libSystem.tbd`; and
listing the real toolchain's directory and the repository's. The staged
`clang --version` ran, the probe read a staged file and listed a staged
directory, and a decoy run by its name was recorded. After the link the
decoy log was empty; the linker had opened 249 files, all under the stage,
and 2,170 members of the archives among them; of the 889 files it looked
for and did not find, none was outside the stage; and the staged pieces
were as they had been staged, so the build wrote into the package's copy
alone. When `sandbox-exec` cannot apply the profile, as in a shell that is
itself sandboxed, the check fails; it never goes on unsandboxed.

**The limit:** this is a sandbox on a machine that has the tools, not a
run on a Mac that never had them. The image's check on the CI runner
(`dmg-check`, which builds the default set from the image) and the owner's
own use are the later evidence.

What else it showed:

- **Lake gives a module's build no inherited `LEAN_PATH`.** It hands
  `lean` the library directories of the workspace's packages and nothing
  else, so with the editor's `.olean` directory on `LEAN_PATH` the
  package's `import Editor.Api` failed with `unknown module prefix
  'Editor'`. The stage therefore holds the editor's modules as a Lake
  package with no target, whose library directory is their `.olean`
  directory, and the fixture requires it by path. Lake builds nothing of
  it, fetches nothing, and wrote nothing into it.
- **Without the stubs the link fails where expected**: in the sandbox,
  `ld64.lld: error: framework not found for -framework ApplicationServices`
  and the same for the other nine, `library not found for -liconv` and
  `-lobjc`, then the undefined symbols.
- **The bundled linker cannot read this SDK's stubs.** Given
  `-F <Xcode 27.2 SDK>/System/Library/Frameworks` outside the sandbox,
  `ld64.lld` 23.1.0 fails on `CoreFoundation.tbd` with `malformed file` and
  `unknown target` at `arm64e.x1-macos`. So requiring the command line
  tools would have meant linking with their own `clang` and `ld`, as
  `--linker system` does, not the bundled linker over their SDK.
- **The relinked editor loads the libraries the built one does**, the
  same 16, at the same versions but two: it names the C++ library by the
  stand-in's install name, `/usr/lib/libc++.dylib`, where the system linker
  writes `/usr/lib/libc++.1.dylib`, and it records the toolchain stub's
  `libSystem` version, 1356.0.0 for 1359.40.3.
- **`/usr/bin/codesign` is the system's own**, not a shim of the tools: it
  loads no `libxcselect`, which `/usr/bin/clang` does. The check requires
  that.
- **A copy of a system program does not run.** A copy of `/bin/cat` or
  `/bin/ls` in the stage was killed as it started (signal 9), outside the
  sandbox too. So the check's probe and its decoys were two small C
  programs, compiled into the stage
  by the staged `clang` against the toolchain's `libSystem` stub, with no
  SDK and no C library headers.

What was not tried:

- A Mac that never had the command line tools, another macOS than 27.2.1,
  and an Intel Mac.
- The relinked editor's window. Only its headless mode was run, so nothing
  here shows AppKit behaves the same in it; passing the SDK version on is
  the one thing done towards that.
- A package of more than one module, one with dependencies of its own, and
  one that calls a system function the built editor does not import: the
  stubs hold only what that editor imports, so such a link would not find
  the symbol.
- Stubs for Objective-C class symbols. The editor imports none (it imports
  `objc_getClass`, which looks a class up by name at run time), and
  `editor_release::stubs` refuses one rather than write a form it has not
  linked.
- A smaller toolchain than the whole of it.
- Compiling the glue with the bundled `clang`: the glue object is prebuilt.
- `--linker system` against the command line tools' own SDK: on this
  machine `/usr/bin/cc` uses Xcode's.
- Shipping files copied from Apple's SDK, linking the Rust library as a
  dynamic library, and loading packages as shared libraries
  (`precompileModules`, `loadDynlib`). Each is a different design.

## Start-up and shutdown

1. The C entry point sets the stack size of the threads Lean creates (see
   "An exception from the interpreter ends the process") and starts a thread
   with a large stack that runs Lean's generated `main`. The real main
   thread stays in Rust and runs the window loop when Lean asks for a
   window.
2. Lean `main` creates the editor state, starts the editor loop on a
   dedicated task, and starts loading config on a background task.
3. The editor is usable before config has loaded: the host registers the
   packages it is handed as its loop starts, before any config
   ("Packages", under "Config and reload"), and the input scheme provides
   the default keymap. Without config the spike reached
   its first event in 0.06 ms; importing the API and elaborating a small
   config took 150 to 200 ms in the background. The window mode is the
   exception since theming phase 7: when it loads config at start it opens
   its window only once that reload has finished, installed or refused, or
   after `Window.configPatience` (3 s), whichever is first. Config chooses
   the window's title bar (`titleBar .standard`, `Editor/Setup.lean`), and
   the platform cannot change a title bar under an open window (winit has
   no setter for it, and restores its own style on fullscreen
   transitions), so the choice must be known before the window exists.
   The cost is the start-up config's load before the window shows (0.17 s
   for the bundle, "What config may import, measured"); its gain is that
   the first frame is drawn in config's theme. The editor loop still runs
   from the start: the reload, an open and anything the echo area has to
   say are handled while the window mode waits. With no config, or when
   the wait runs out, the window opens with the themed title bar.

Shutdown posts a quit event, unblocks every dedicated task, and calls exit.
Returning from `main` while a task is blocked in Rust hangs.

**Session restore at start-up, as built** (session-restore phase 1;
`lean/Editor/Restore.lean`, `lean/Editor/Restore/Run.lean`). With a state
directory a host's first request is `restore`: the window mode's first
start (`Window.Options.starts`), and the headless mode's when it is given
`--state`. It starts the job `restore`, which makes
`<state>/session/journals/`, lists the session's files and loads them; its
command restores each buffer with unsaved text, and its second half,
`restore-files`, stats their files and reopens the files with none. **The
host holds the driver's requests that follow** (the command-line file's
open, what is said, the start-up reload) and handles them in order once the
restore has finished (`Restore.Kept.restored`) or its jobs have failed;
window events are handled meanwhile, and `Host.await` waits while it is in
flight, so the window mode's wait for the start-up reload waits for it too.
So packages register first (`Running.new`), the restore runs next, and
config's `setup` runs in the reload after it. A major mode only config
registers is deferred until a config has installed, and set then, or said
when that config does not register it.

**Shutdown waits for the journal.** Once the loop has ended, a host waits,
for at most 2 s (`Headless.drainPatience`), until the file service holds no
request, so the journal's last orders (a clean end's removes and its ended
index) are written, then quits the queues.

**Restart, as built** (session-restore phase 3;
`lean/Editor/Restore/Restart.lean`, `crates/editor-launch`,
`crates/editor-launch-std`). `:restart` re-execs the running executable and
`:restart <exe>` (`Editor.restart (into := …)`, which packages phase 8's
install calls) another, with the session handed over:

1. **The probe.** The command `restart` runs `<target> --probe` through the
   process service, in the editor's own environment, for at most 10 s
   (`Restore.probePatience`). It must exit 0 with the first line `probe:
   ok`: `--probe` (`lean/Editor/Executable.lean`) returns once `main` is
   reached, so every module initialiser has run, packages' `initialize`
   among them. Otherwise the restart is refused, said with how the probe
   ended and its first line of standard error, and the editor keeps
   running. That catches what fails before `main`: a bad link, a bad
   signature, a missing library, an `initialize` that throws. With no state
   directory, before the restore has finished, while a restart is in
   flight, or for an executable that is not an absolute path, `:restart` is
   refused at once.
2. **The hand-over in flight** (`Restore.Kept.handing`). From the probe's
   success the loop drops the user's input (keys, committed text, a
   preedit, the pointer) and says `restart: handing the session over; the
   window closes and reopens` in the echo area, with ` (no launcher, so no
   fallback)` for a run no launcher started; the editor does not leave
   meanwhile (`EditorState.leaves`). Once no save is in flight, the
   reconciler hands back its journal orders and starts `restart-save`, which
   saves this run's index, not ended, over `session-<run>.json`, then the
   hand-over record (`<state>/session/handover`,
   `lean/Editor/Restart/Handover.lean`), each a snapshot saved by the file
   service, whose one queue works them after every journal order handed
   before them: the host hands a step's journal orders to the file service
   before it starts the step's jobs. A save refused is said, the record
   removed, and the hand-over given up.
3. **The end that execs.** The save's command hands the host the plan
   (`Loop.Stepped.handOver`). A host that counted a journal failure since
   the hand-over began runs `restart-abandon` instead, which says it and
   writes a new generation of every journal. Otherwise the host ends its
   loop, shuts down as at any end (the children, the watches, the searches,
   the bounded drain of the file service, the queues), the window mode
   closes its window, and execs the plan through its collaborators' exec
   alone (`Headless.Collaborators.replace` and `Restart.Plan.exec`, one
   step both hosts share; `Restart.real`, over `Ffi.exec`, in the
   executable, and a fake in `ffi-test window-host-restart`): with a launcher, `<launcher> --handover <record>`; with
   none, the first candidate with `--restore <index> --handed-over <record>`
   and the host's arguments. An exec that fails is said on stderr and the
   process exits 1; the session is restored at the next start.
4. **The next run** is given `--launched-by`, `--shipped`, `--restore`,
   `--handed-over` and a `--failed` for each executable that failed, first
   on its command line, which the executable strips before it chooses its
   mode (`Restart.Launch.strip`). Its restore takes the named index in place
   of the highest (`Document.choose`); one that is missing or does not
   parse is said and the version rule decides. Its summary starts
   `restore: restarted, so the window was closed and reopened;` and names
   the executables it fell back past. Once the handed index is restored and
   its own index written it removes the record: **the hand-shake**. A run
   that ends cleanly before it removes the record too. A
   `session/handover.failed` the restore finds (every candidate failed) is
   said in `*restore*` with its candidates, and removed.

**The launcher and its fallback.** `leanmacs`, the bundle's
`CFBundleExecutable`, starts an editor by `exec`: cold, the default
(`Contents/MacOS/editor` beside it, or an explicit `--default`) with
`--launched-by` and `--shipped`; from a hand-over record, the first
candidate neither marked failed nor missing (the new executable, the
previous, the shipped default, each once). Just before each hand-over's exec
it spawns its **watcher**, detached (an intermediate that starts it and
exits, so it is nobody's child) with the editor's standard streams, which
waits for the record to go (exit 0), for the process to end with the record
still there (whatever its status: it marks the candidate `failed` and execs
the launcher again, which starts the next), or for 60 s (it kills the
process first). An exec that is refused marks the candidate failed and the
next is tried in the same process. With none left the record is renamed
`handover.failed` and the launcher exits 1: the index is not ended, so the
next start restores it by phase 1's rule. A record of a later format is
left as it is and the launcher starts cold. The whole decision
is `editor-launch`'s core, on ports, pinned on fakes; the real adapters are
held to the ports' contract and run end to end in `tests/fallback.rs`.

**A cold start picks the newest per-user editor** (packages phase 8;
[packages.md](packages.md), "User package sets"). The launcher reads the
core's identity beside the default (`<default>.core`) and lists
`<data>/editors/<core>/`, `<data>` being `--data`, else `leanmacs` under
`$XDG_DATA_HOME`, else under `$HOME/.local/share` (an empty variable is
unset; neither set, no per-user choice). It considers only numeric
directories that hold `editor`, so a staging directory and another core's
editors are never started (`crates/editor-launch/src/editors.rs`). With
none, or no `.core` record, it execs the shipped default as before.
Otherwise it writes a **cold record**, `<data>/launch/cold-<pid>`: the
hand-over record with no `session` line, its candidates the newest, the
one before it and the shipped default, and the editor's arguments; then it
goes down the hand-over path, spawning the watcher and exec'ing the newest
with `--launched-by`, `--shipped` and `--handed-over <record>`, and no
`--restore`. A run handed a record with no `--restore` is a cold start
under watch: it removes the record at its restore's hand-shake, at once
when it has no state directory, and in `--probe` once `main` is reached
(`Restart.Launch.removedAtStart`, `probeRemoves`). So when the newest ends
before that, the watcher starts the previous one, then the shipped
default. The record's format stays 1: only the launcher writes and reads a
cold one, and the Lean encoder always writes `session`. A per-user editor
started outside a bundle with `--shipped <bundle>/Contents/MacOS/editor`
takes that bundle's toolchain as its default sysroot
(`ModuleLookup.resolve`).

**The first launch after an editor update** finds every per-user editor
under the old core's identity, so the launcher starts the shipped default;
its start-up reload sees the lakefile differs from its own fingerprint and
builds the set against the new core, then restarts into it. When that
build fails, the shipped default keeps running with the errors in
`*package-build*`. No per-user editor is started before the rebuild.

**The window closes and reopens.** It is not handed across the exec: the
window mode closes it once its loop has ended for the hand-over, and the
next run opens its own.

**`editor [<file>]`, as built** (the display pipeline's last phase;
`lean/Editor/Window.lean`, `lean/Editor/Window/Real.lean`). The window mode
is the headless host's editor loop handed real collaborators: the real
display binding over a display on the system's fonts, bound to the
process's presenter, and the system clipboard, or `Clipboard.unavailable`
when it cannot be opened, which the echo area says once. Before the first
event `main` posts the open command with the file, when one was given
(with none the editor shows its one empty buffer), what the echo area has
to say, and a reload when config is loaded at start; the editor loop runs
from then on. When config is loaded at start, `main` waits for that reload
to finish, or for 3 s, and opens the window with the title bar the
installed config chose (`Window.titleBarAtOpen`), as above. Then it runs
the window on its own thread (`Ffi.windowRun`) with the editor loop on a
dedicated task; when the
loop ends, once a close request or `:q` can leave, a task waits briefly for the last
frame to be drawn and asks the window to close. Then `main` quits the
queues and exits.

- **The toolchain.** In an app bundle, an executable at
  `<bundle>/Contents/MacOS/<name>`, it is `Contents/Resources/lean/toolchain`,
  a sysroot whose modules are under its `lib/lean`. Outside a bundle Lean
  cannot run `lean --print-prefix`, which would spawn a process, so the
  toolchain's directory is an argument (`--sysroot`). With none, no config
  is loaded, and the echo area says
  `config: not loaded: no Lean toolchain given (--sysroot)`. `mise run
  edit` always gives the pinned one.
- **The editor's `.olean` files** are, in a bundle, in the directories
  the bundle's record `Contents/Resources/editor.oleans` names, relative
  to `Contents/Resources`: the staged core's and each default package's
  own build directory ("Build", "The app ships the toolchain"). Outside one they are where the build
  that linked the executable recorded them, unless `--oleans` says
  otherwise. The editor is linked from a package set into the set's build
  directory, and each Lake package's modules are built in that package's
  own, so no directory relative to the executable holds them
  ([packages.md](packages.md), "The generated root"). The package-set
  build writes `<executable>.oleans` beside the editor it links: one
  directory a line, the core's first, then that of each other package of
  the set that holds a library, in the order they register. The window
  mode and the headless mode read it at their edge, and the elaborator
  searches every directory of it, in order, beside the toolchain's: the
  base config is elaborated on is the set's, `Editor` and then the entry
  module of each package of the set outside the core
  ([packages.md](packages.md), "The config base of a set"), and each
  package's `.olean` files are in its own directory. A directory given on
  the command line is a search path too, one directory or several joined
  with `:`, searched before the recorded ones, which are still added; in
  a bundle the directories given are used alone, in place of the bundle's
  one, which holds every module of the base. An executable with no record
  has no default: with a
  toolchain and no `--oleans` no config is loaded, and the echo area says
  so and what to give (`Window.noModules`): `--oleans` with a search path,
  directories joined with `:`, that holds the core's `.olean` directory
  and every package's of the editor's set; in a checkout,
  `lean/.lake/build/lib/lean` and each package's `.lake/build/lib/lean`.
  The core's directory alone is not enough for such an executable: the
  base holds each package's entry module, so the import of the base is
  refused. The elaborator adapter then says, in one line, which base
  module has no `.olean` file, the directories searched, and that an
  executable with no record must be given every package's directory,
  joined with `:` (`Config.Elaborate.notImported`,
  `ConfigTest.elaboratorChecks`); Lean's own message names only a module
  prefix the user never wrote. Before the
  editor came from a package set the default outside a bundle was
  `<directory of the executable>/../lib/lean`, where Lake put the modules
  beside the executable; for a set's editor that directory holds only the
  generated root. `mise run edit` gives `--oleans` as it gives `--sysroot`.
- **The package set the editor was built from** is found the same way, for
  the lakefile the editor generates in a config directory ("Config and
  reload"): outside a bundle, the build writes the set's directory beside
  the editor it links, in `<executable>.set`, one line, absolute; in a
  bundle it is `Contents/Resources/lean/set`. A directory that is not
  there is none, and an editor that knows none generates no lakefile: a
  bundle holds no set yet (`ModuleLookup.setDirectory?`). The set's Lake
  name and the toolchain pin are not found but handed in: the generated
  root passes them to `Editor.Main.run`
  ([packages.md](packages.md), "A config directory requires the core and the set").
- **Where both are found** is a pure function of the executable's path,
  read from `IO.appPath` at the edge, of what the build recorded for it,
  read at the same edge, and of the directories the command
  line gave, each of which overrides its own default wherever the
  executable is (`lean/Editor/ModuleLookup.lean`). The bundle is known by
  its layout alone, not by a `.app` suffix. Nothing is read from the
  environment: `LEAN_PATH` is ignored, as the elaborator ignores it. It is
  pinned in `model-test` (`ModelTest.moduleLookupChecks`,
  `windowOptionChecks`, `headlessCommandLineChecks`).
- **The config directory** is `--config`, or `leanmacs` under
  `$XDG_CONFIG_HOME`, or under `$HOME/.config` when that is unset. A
  default directory that does not exist loads nothing and says nothing; a
  given one that does not exist is a rejected reload, said in the echo
  area. Reloading again is `:reload` (`reload-config`); nothing is watched.
- `main` reads the working directory, those two variables and the
  executable's path at the edge; what they mean is a pure function,
  pinned in `model-test` (`ModelTest.windowOptionChecks`).
- **Failures are said, and are status 1.** A window that cannot be opened
  is `editor: the window could not be opened: <reason>` on stderr. A
  window whose renderer cannot be made (no adapter, no device, no
  surface), or whose render thread panics, still runs, with every input
  reaching the loop and nothing drawing in it. The library knows why
  (`Session::failure`) but Lean learns it only from the run's reply, once
  the window has closed (`Ffi.WindowRan.nothingDrew`): the window mode
  then prints `editor: nothing could draw in the window: <reason>` to
  stderr, says it in the echo area if the loop is still running, and
  exits 1. While the window is open the person sees a window that never
  draws; saying so sooner would need the library to tell Lean while the
  window runs, which nothing does yet.

**Quit from a command, as built.** A command cannot end the process. It
asks (`quit`, `lean/Editor/Api.lean`), which sets a flag of the editor
state; the loop's step says stop once the editor can leave, when no buffer
that holds a file has unsaved changes and no save is in flight
([concurrency.md](concurrency.md), "Quit"); the host ends its loop, as it
does once a window's close request, a quit by the same rule, can leave;
and the executable's `main` then quits
the queues and exits, as it does at the end of a script. The headless
mode's driver sees a loop that ended by itself, stops reading its script
there, and exits with status 0
([headless-mode.md](../dev-practices/headless-mode.md)).

**The window, as built.** The main thread is parked in a small service
(`crates/editor-ffi/src/main_thread.rs`), and "run the window" is one
request of it, with which platform and how the window is opened. The main
thread then runs the window's loop to its end, so the Lean thread that asked
is blocked until the window has closed: Lean asks from its main thread or a
dedicated task, never from the pool. What the window reports arrives on the
editor queue, each event stamped with the instant the window's loop was
handed it, and a Lean loop on a dedicated task pulls it.

- **Lean closes the window.** When the user asks for it to be closed, the
  window reports that and stays open; Lean calls the close binding, the
  loop ends, and the request returns. Rust never ends the window by itself.
- **While the window runs, the main-thread service answers nothing else.**
  Requests to the window go through the window's own loop
  (`editor_ffi_window_request`: enter or leave fullscreen, minimise), never
  through the service: the request is put on the adapter's channel and the
  loop is woken, so it never blocks the Lean thread that asks.
- **The window's title is the scene's** (`Scene.title`, the selected
  buffer's name). It is published with every scene, and the library sends
  it to the window only when it changes.
- **Files Finder and the Dock open the app with arrive from the window**,
  as an `openFiles` event with their absolute paths, after `windowOpened`
  and the resize after it, never on the command line: a Finder start posts
  no open. The loop runs `open-file` with the paths, as an invocation no key
  yielded, in the focused window, and the open command opens them one after
  another, so the last path's buffer is shown last (`lean/Editor/Loop.lean`,
  "What each event does"; [rust-library.md](rust-library.md), "Files the
  system asks the app to open").
- **The window runs once in a process**, which is all winit allows.

The one thing that runs a window today is the keyboard check
(`lean/Editor/WindowCheck.lean`; `editor window-check`), which a person runs
to see that keys reach a Lean loop, and how fast.

What is built of this is the headless mode (`lean/Editor/Headless.lean`;
`editor headless [<sysroot> <olean dir>] <config dir> <script file>`): an
editor loop on a dedicated task with no window and no keymaps, which loads a
config directory in the background, runs its commands against the library,
starts its jobs and prints what happened. It exists for integration tests.
It runs the command loop (`lean/Editor/Loop.lean`): events from the window
input go to `Loop.step`, which handles each against the editor state
(`lean/Editor/State.lean`) and publishes a scene; after every other event,
a driver's request, a reload's install or a job's command among them, a
scene is published too. With no window, the display is a recorder of the
scenes (`lean/Editor/Display/Recorder.lean`), and the frame is made, 0 by 0,
at the first event from the window input, so that the texts commands make
before it keep their indices. The first load is an ordinary reload: the
loop answers events before and while it runs. The toolchain's directory
and the editor's `.olean` directory are its first two paths, the second a
search path that the directories the build recorded for the executable
follow, as for the window mode (above), so the core's directory alone is
enough for an editor a package set's build linked; from an
executable in an app bundle they may be left out, and are then the
bundle's, resolved as the window mode's are. Outside a bundle two
paths are refused, status 2, because there is no toolchain to use: the
headless mode never falls back to the environment or the working
directory (`lean/Editor/Headless/CommandLine.lean`).

Before its loop starts, the headless mode does what the command loop's
start-up will:

- **It warms the pool** (`Pool.warm`, `lean/Editor/Job/Pool.lean`), so the
  first burst of jobs finds every pool thread made. The pool keeps Lean's
  size ([concurrency.md](concurrency.md), "The pool").
- **It starts the completion pump** on a dedicated task
  (`lean/Editor/Job/Real.lean`), which pulls the completion queue for the
  life of the process. Quit ends it, like every pull.

Its script has a directive for each thing a driver can ask: `reload`,
`run <name>`, `spawn <name>`, `show` and `scene` (the last scene published),
two waits of the driver's own, `settle` (no reload is running) and `join`
(no job is running), and two events sent as a window would send them,
`key` and `commit`.

Rules found the hard way:

- **Module initialisers must not call the Rust library.** The `lean`
  compiler runs a module's `initialize` declarations when it compiles a
  module that imports it, where the Rust symbols do not exist, so one that
  calls a binding fails the build. A plain constant whose value calls a
  binding is not run by the compiler: it builds, and runs in the module's
  initialiser when the executable starts, so only review keeps those out
  (`lean/Editor/Ffi.lean`, "Nothing runs at initialisation"). Create library
  objects from `main`.
- **Rust objects are Lean external objects with finalisers**, never bare
  integers, so a handle cannot be used after it is freed.

### The app's identity across an exec

macOS knows an app by its bundle: LaunchServices registered the process it
launched by its pid, and the Dock icon, the menu bar's name, file
associations and the open-file events Finder sends follow from the bundle
CoreFoundation's main bundle is (`CFBundleGetMainBundle`, which
`NSBundle.mainBundle` and AppKit's check-in are built on). An executable
outside the bundle, as packages phase 8's per-user executable will be, is
by default its own directory's "bundle", with no identifier.

**Decided** (session-restore phase 3, decision 1): exec through a launcher
inside the bundle, which sets `CFProcessPath=<bundle>/Contents/MacOS/leanmacs`
in the exec's environment. CoreFoundation's `_CFProcessPath` honours that
variable in a process that is not restricted, which an ad-hoc-signed app
without the hardened runtime is not, so the main bundle is the app wherever
the executable lives. `IO.appPath` (`_NSGetExecutablePath`) is unaffected,
so `ModuleLookup` still finds an executable's own modules by its real path.
The process service removes `CFProcessPath` from every child's environment,
so a program the editor runs never takes the app as its own bundle.

- **Why a launcher, not a direct exec of the per-user executable.** A cold
  start from Finder must reach an executable outside the signed bundle,
  which may sit in a read-only `/Applications`, so it can never be
  `CFBundleExecutable` itself; the fallback needs a process that outlives a
  failing executable; and the identity is set in one place.
- **Why `exec`, not a child.** LaunchServices registered the launched pid. A
  child would check in as a second instance, with a second Dock icon, and
  miss the open-documents event of a cold start, which goes to the launched
  process.
- **Everyday use runs this path**: every start passes through the
  launcher's exec. Until phase 8 a cold start runs the shipped default.

**What is checked, where.**

| Where | What |
|---|---|
| The gate, macOS leg: `crates/editor-launch-std/tests/identity.rs` | In a fake bundle: the launcher's cold start runs the bundle's editor as the app; a hand-over to an editor outside the bundle, and an explicit `--default` outside it, is the app too, in the launcher's own pid; the same editor run directly is not |
| The gate, both legs: the launch fixtures `tests/launch/handover-v1` and `tests/launch/arguments-v1`, read by both sides | What crosses between Lean's restart and the launcher, as files: Lean's encoding of the hand-over record is `handover-v1` (`ContractTest.launchRecordChecks`) and the launcher decodes it (`editor_launch::handover`'s fixture test); the launcher execs a hand-over's candidate with the arguments of `arguments-v1` (`editor_launch::launch::tests::the_hand_over_exec_arguments_are_the_checked_in_fixture`) and Lean takes its launch flags back from them (`ContractTest.launchRecordChecks`). The decisions on each side are their own tests' (`ModelTest.restartChecks`, `restartHandoverChecks`; `editor_launch`'s `launch` and `watch` tests) |
**Seen once on a desktop** (2026-11-20, an Apple M5 Max, macOS 27.2.1,
arm64), and checked by no test: a copy of the app, restarted into an
editor outside the bundle once AppKit had checked in, kept LaunchServices'
record of the process (one instance, the same pid, the copy's
`bundlepath` and name); open-file events reached the new executable; and
when a restart into a failing executable fell back, the watcher, which
LaunchServices did not launch, started the previous executable with the
same record. The Dock icon's pixels were argued, not observed: the Dock
draws the icon from that bundle's `CFBundleIconFile`, and no tool reads
the Dock's drawn icon back without the Accessibility permission, which a
person would have to grant.

So an exec after AppKit's check-in keeps the identity, and decision 1's
contingency (handing over with `open -n -a <bundle> --args --handover
<record>` in place of an exec) is not needed.

**A risk to recheck.** The hardened runtime that notarization requires may
mark the process restricted, and CoreFoundation then ignores
`CFProcessPath` (task `recheck-cfprocesspath-under-hardened-runtime`).

## Config and reload

Lean environments are immutable and a declaration cannot be redefined. So
config is Lean modules, and a reload builds a new config from the files as
they now are and swaps it in.

A config directory is a small Lake package:

```
init.lean            the root: the one file whose `setup` the editor runs
Config/Keys.lean     any other config file: the module `Config.Keys`
lakefile.toml        generated when absent
lean-toolchain       generated when absent
```

- **Each config file is a module of its own.** A config is the root and
  the config files it imports, directly or through others. Each file is
  elaborated after the files it imports; a config file other than the root
  has its module data written once, and the files that import it import
  that. So after a change, a reload elaborates that file and the files that
  import it, and no other (`Config.plan`). One environment chain could not
  give that: a Lean environment is linear, and Lean 4.35 has no merge of
  two environments, so a file that came after the changed one in a chain
  would be elaborated again though it does not import it. A file under
  `Config/` that nothing imports is not read.
- **A file writes its own header.** `import Editor`, and `open Editor` to
  name the editor's declarations with no prefix. Nothing is imported or
  opened for it, which is what Lean's language server needs to accept the
  file. A file that starts with `module` is refused: config files are plain
  modules.
- **What a file may import** is one of three things. `Config.<Name>` names
  a config file, `Config/<Name>.lean`; a file that is not there is a
  diagnostic at the import, and so is a cycle, which is named. A module the
  base holds, or a module of `Init`, `Std` or `Lean`, is linked into the
  editor and is loaded. Anything else rejects the reload, at the import's
  line, naming the module: `module … is not linked into this editor`.
  Every header is read, and every problem found, before anything is
  elaborated.
- **A module's name is exact about case**, on every file system. On one
  that ignores case, macOS's default, a test of whether a path exists
  answered yes for `Lean/data/json.olean` and `Config/keys.lean`, so
  `import Lean.data.json` was accepted and `import Config.keys` loaded
  `Config/Keys.lean` as a module of another name: a config that loaded on
  a Mac and nowhere else. So a config file, and a module of the toolchain
  the base does not hold, are found by listing each directory on the path
  and requiring an entry equal to the name byte for byte
  (`lean/Editor/Config/ExactPath.lean`), and a module the base holds by
  its name in the base. An import whose name is another module's but for
  case is refused at the import, naming the file found and the spelling to
  use (`Config.misspelt`); a file `Init.lean` is no root.
- **When that module belongs to a package the config's lakefile names**,
  the diagnostic says the package set needs a rebuild. The editor reads the
  `[[require]]` names of `lakefile.toml` from its text, with Lake's TOML
  loader, and never runs Lake; a package named `greeting-loud` owns the
  modules under `GreetingLoud`, the entry-module rule's casing. A
  `lakefile.lean` is not read, and then the plain diagnostic is given.
  Every host reads the lakefile, the headless mode too: reading is a port
  of its own, apart from the one that writes
  (`lean/Editor/Config/Session.lean`, "The package ports").
- **The base grows with what config imports.** It starts as the set's base
  ([packages.md](packages.md), "The config base of a set"), and a module of
  `Std` or `Lean` is read on its first import and never twice in a process.
  A base of every linked module from the start was measured and refused: it
  cost 0.61 s and 1.40 GB resident for each headless start, against 0.23 s
  and 0.60 GB. A file kept from an earlier reload stays valid when the base
  grows: a module built on a smaller base imports beside a larger one.
- **A reload is all-or-nothing**: if any file fails to elaborate (including
  a theorem that no longer holds), an import is refused, or the root's
  `setup` throws, the old config stays.
- **Only the root's `setup` is run.** The editor runs the constant `setup`
  that `init.lean` itself declares. A config file under `Config/` exports
  its programs under names of its own, and the root's `setup` calls them. A
  `setup` defined in another config file is not run, whether or not the
  root imports that file; a root that declares none is refused with a
  diagnostic that says so.
- **The old form is refused.** A directory with no `init.lean` that holds
  `.lean` files directly in it is config in the form of byte-ordered chunks
  with no header, which the editor loaded before config was modules. The
  reload is rejected with one diagnostic that names the files and the fix,
  `mise run config-migrate`, which converts the directory so that it loads
  as it did (the `config-migrate` binary, `editor_config_migrate::migrate`).
  - The files, in byte order, are cut at the first that defines `setup` or
    declares something `private`. Each file before it becomes
    `Config/<Name>.lean`, with the header and an import of the file before
    it, which keeps what each chunk saw. That file and the ones after it
    become `init.lean`, in order, each but the last in a `section`, so
    what it opened ends where the chunk ended.
  - The cut is what the two forms' difference asks for. The old form ran
    the `setup` of whichever chunk defined it, and the editor now runs the
    one the root itself defines: a `setup` in an imported module could not
    be defined again in the root, so its file is the root's. And the old
    form's chunks were one module, so a `private` declaration of one was
    visible in the next, which it is not across modules.
  - With `setup` in the last chunk and nothing private before it, the
    common shape, the last file is `init.lean` and every other is under
    `Config/`.
  - It tells from the text, a line at a time, with no Lean. When no line is
    seen to define `setup`, every file goes in `init.lean`, which always
    loads.
  - One shape is refused by name, with nothing changed: a file that would
    go in `init.lean` before another and leaves a namespace, a section or a
    `mutual` block open at its end. In the old form that ended with the
    chunk; in one file it would swallow the files after it, and the script
    cannot name what to close.
  - A file that already starts with an import header is refused by name
    too: it is no chunk of the old form, and a second header before its
    text would leave its own after a command.
- **A misspelt root is not the old form.** The root is found by exactly
  its name, so a directory that holds `Init.lean` and no `init.lean` has no
  root, on a file system that ignores case as on one that does not. Rather
  than the old form's diagnostic, whose command would refuse the file, the
  reload is rejected with one that names the file and says to rename it to
  `init.lean`.
- **The editor generates the two other files when they are absent, and
  never rewrites one that is there** (`lean/Editor/Config/LakePackage.lean`).
  The lakefile requires the package set the editor was built from, by its
  directory, and declares the library `Config` of every module under
  `Config/`; `lean-toolchain` is the editor's pin. A `lean-toolchain` that
  names another toolchain is a warning in the reload's report that names
  both.
  - **An editor run from a checkout writes both.** It finds its set's
    directory in `<executable>.set`, which the build writes beside it
    ("Start-up and shutdown").
  - **The app writes both too since the packages roadmap's phase 9**: the
    lakefile requires the set the bundle ships,
    `Contents/Resources/lean/set`. An editor that knows no set directory
    writes `lean-toolchain` alone, and says as information that no
    lakefile is generated, in the report of every reload that finds the
    directory without one. It is said each time, not once: nothing
    then has to remember that it was said, and a first reload that is
    rejected before the files are generated cannot swallow it. An
    installed reload's information is in its report and not in the echo
    area. An
    editor writes a lakefile only when it knows a set directory that is
    there, since Lake rejects a lakefile whose `require` names a path that
    does not exist, and the editor would never rewrite it.
  - **The window mode generates; the headless mode only with
    `--generate`**, so the config directories under `tests/` are never
    written to.
- **`init.lean` is outside the generated library**, so Lake never builds
  it. A TOML lakefile cannot declare "every file here" (Lake refuses a glob
  with no name), so top-level config files would need the lakefile
  rewritten whenever one is added. And on a file system that ignores case,
  macOS's default, a built `init.olean` is found for Lean's own `Init`:
  with `init` in a library, `lake build` followed by any compile in the
  directory ended in `Stack overflow detected. Aborting.` after 99 s in a
  prototype. A user who adds `init` to a library by hand meets that.
- **Lean's language server checks a config file as the editor elaborates
  it.** Started in the config directory (`lake serve`), it reports no
  import error for a file that imports `Lean`, a module of a package of the
  set and a config file, and reports a type error at its position. The gate
  holds that on a config package config-test writes as an editor of the
  default set generates it (`ConfigTest.lspChecks`: the lakefile
  `Editor.Config.LakePackage.lakefile` gives, the core's pin). It writes
  `lake-manifest.json` and `.lake/` in the config directory, and builds
  there the config files a file imports; it fetches nothing and builds
  nothing under the set.
- **The editor is more lenient than the server in one way.** A file with no
  config import is elaborated on the base as it is, so it sees every module
  the base holds, imported by it or not: once one file's `import Lean` made
  the base hold `Lean`, the editor accepts another file that uses `Lean`
  without importing it, and the server rejects that file. The reverse does
  not happen for config files: each sees only the config files it imports.
- Scratch evaluation (a REPL) sits on top and is discarded by a reload. It
  is not built: the prototype's was not carried into the executable.

Config defines commands and a `setup` action that registers them: key
bindings, subscriptions, options. The editor runs `setup` after a successful
elaboration. Closures that config registers are stored in compiled state
(the keymap holds them) and keep working; calling a stored closure was no
slower than a compiled command in the spike.

**Measured**, with `mise run config-bench`, which is run by hand and asserts
nothing (2026-11-19, an Apple M5 Max, macOS 27.2, Lean 4.35.0):

| | |
|---|---|
| A reload of a one-line root | 2.0 ms (median of 20) |
| Of a 20-line config, one file | 9.3 ms |
| Of 50 definitions with a `simp` proof, one file | 38.9 ms |
| Of the same 50 definitions in a config file the root imports, on a base that holds `Lean` | 283.6 ms |
| Soak, a root alone that imports `Lean` and uses it (the 50 definitions): resident memory after 100 reloads, and after 500 | 1,440.3 MB, 1,440.0 MB: 0.0% apart; 40 ms a reload |
| Soak, a root and an imported config file that changes each round, on a base with `Lean`: after 100, and after 500 | 1,635.9 MB, 1,671.9 MB: +2.2%; 285 ms a reload |

- **A config of `init.lean` alone reloads as fast as before config was
  modules**: its root is elaborated on the base's environment, with the
  parser started after the header.
- **A reload that touches an imported file costs tens to hundreds of
  milliseconds more.** A file that imports config files gets an environment
  of its own, made from the base's import state and their module files. In
  a prototype that took about 30 ms on the set's base and 120 ms on a base
  that holds `Lean`, and the first elaboration in a new environment 23 to
  55 ms more. In the executable as built, the row of 283.6 ms is about
  39 ms for the config file and about 245 ms for the root's environment and
  the root, on a base that holds `Lean`.
- **Finding a file exactly costs nothing measurable.** Listing each
  directory on a path, in place of one test of existence, is done once for
  the root and once for each config import in a reload, and for a module of
  the toolchain only while the base does not hold it. With `bench-reload`
  and `bench-reload-directory`, medians of 20, before and after it (two
  runs of each, 2026-11-19, the machine above): the 50 definitions in one
  file, 38.4 ms before and 38.9 ms after from memory, 38.3 to 38.6 ms and
  38.8 to 39.1 ms from a directory; the same in an imported file on a base
  with `Lean`, 277.4 to 277.9 ms and 279.4 to 280.5 ms from memory, 276.2 to
  276.4 ms and 278.4 to 278.5 ms from a directory. That is under 1%, within
  what two runs of one build differ by, so a reload keeps no cache of
  listings.
- **Replaced configs are freed.** Both soaks stay within 5% from 100
  reloads to 500, the bound the phase set; memory is reported, never
  gating.
- **The importing path leaks a little, on purpose.** A module file is read
  again for each environment that imports it, and the memory it is read
  into is never freed: freeing it is unsafe while a closure of an old
  config may be alive. That is the +2.2%: 36 MB over 400 reloads, about
  90 KB a reload of this config, whose module file holds 50 definitions.
- **The module directory** is a temporary directory the host makes when the
  first config file's module data is written, and removes when it ends. A
  process that crashed leaves it to the system's cleaning of temporary
  files.

Known limits: compiled code cannot be swapped. The Lean internals the
session rests on can change with a toolchain bump:
`Lean.importModulesCore` on a retained `Lean.ImportState`,
`Lean.finalizeImport`, `Lean.ImportArtifacts` and `Lean.writeModule`, which
config as modules added, beside `Lean.Parser.parseHeader`,
`Lean.Elab.IO.processCommands` and `Environment.evalConst`.

### The config session as built

The session is a pure core with ports, and two adapters that link Lean's
frontend: one elaborates, and one reads a lakefile's requires with Lake's
TOML loader.

| Piece | Where |
|---|---|
| What config registers with: `setup`, a program over the setup port | `lean/Editor/Setup.lean` |
| Stores: a value of config's type as a plain tree with a version | `lean/Editor/Store.lean` |
| Diagnostics: failure as data | `lean/Editor/Config/Diagnostic.lean` |
| Owners: who registered or started something | `lean/Editor/Config/Owner.lean` |
| A package: a name and a `setup`, how a feature registers | `lean/Editor/Package.lean` |
| Registering packages: a package's owner, what its `setup` means and what is refused, and the config state a host starts from | `lean/Editor/Config/Packages.lean` |
| The executable's entry: the dispatch on the command line's mode, handed the packages | `lean/Editor/Main.lean` |
| Faces: what a face looks like, as data, the built-in theme and a theme with its name | `lean/Editor/Face.lean` |
| The registry of commands, of jobs, of key bindings, of modes, of ex bindings, of faces, of themes, of mode-line segments and of menus, replaced by owner, the keymap of the bindings, a mode line resolved from a listing, the menu bar, and the handler that collects a `setup` | `lean/Editor/Config/Registry.lean` |
| The mode line: segments, from what a window shows to status fields; the shipped ones and their default order; a listing resolved into a mode line; and the fields of a window, selected or not | `lean/Editor/ModeLine.lean` |
| An ex line and an ex binding, as data | `lean/Editor/Ex/Line.lean` |
| What a command is run with when a key runs it: the focused window and its buffer, the arguments and the keys | `lean/Editor/Command/Call.lean` |
| The cells of the stores, and the rule that installs a config's stores | `lean/Editor/Config/Stores.lean` |
| One reload: the ports, the import graph, which files a reload keeps, the build | `lean/Editor/Config/Session.lean` |
| The config directory as a Lake package: the generated lakefile's text, and what to do given what the directory holds | `lean/Editor/Config/LakePackage.lean` |
| The library a package's modules are under, and which of a lakefile's requires a module belongs to | `lean/Editor/Config/Lakefile.lean` |
| A lakefile's requires, read with Lake's TOML loader | `lean/Editor/Config/Lakefile/Toml.lean` |
| The elaborator port's pure model, and the contract it and the real adapter are held to | `lean/Editor/Config/Elaborator/Model.lean`, `Contract.lean` |
| The reducer that serialises reloads and installs their outcomes | `lean/Editor/Config/Reload.lean` |
| Handing a display the theme a reload installed | `lean/Editor/Config/Display.lean` |
| The elaborator port answered by Lean's elaborator | `lean/Editor/Config/Elaborate.lean` |
| The source port answered by a config directory, and the directory read and written as a Lake package | `lean/Editor/Config/Directory.lean` |
| The headless loop: the editor thread, the reload job, the output, and the command loop run against the library with a display recorder | `lean/Editor/Headless.lean` |

- **The core has no elaborator in it.** Which files are a config, what a
  file may import, the order they are elaborated in and what each is
  handed, which loaded files a reload keeps, all-or-nothing, when `setup`
  runs, replacement by owner, the store rule and the serialising of reloads
  are plain Lean with no `import Lean`, tested by `lake test` on a pure
  model of the elaborator port and hand-written fakes of the others
  (`ModelTest.sessionChecks`, `reloadChecks`). Two modules link Lean's
  parser and elaborator, each an adapter: `Elaborate.lean`, which turns a
  config file into a module, and `Lakefile/Toml.lean`, which reads a
  lakefile's requires with Lake's TOML loader
  ([overview.md](overview.md), "Rules of the boundary"). `config-test`
  checks them, the directory source and the whole host against the real
  collaborators (`mise run ffi-test`).
- **The elaborator port has a pure model, and one contract holds it and
  the real adapter together.** The model reads a small language of its own
  (`import`, `define`, `use`, `fail`, `warn` lines) and the adapter reads
  Lean, so a property of the contract writes a file as abstract lines and
  each side says how those are written. The properties are what the
  session core rests on: a header's imports with their lines, a diagnostic
  tagged with the file's path at its line, a file that sees what a module
  of the base declares, a base that grows, a file that sees a config file
  only when it is handed that file's handle (which is what makes keeping an
  unchanged file sound), a handle that is one version of a file, and a
  `setup` that is the root's own. `model-test` runs them on the model and
  `config-test` on Lean's elaborator
  (`ModelTest.elaboratorContractChecks`,
  `ConfigTest.elaboratorContractChecks`).
- **`setup` is a program over a setup port**: `SetupM Unit`, whose requests
  carry what is registered (a command, a store, a command over a store, a
  job, a face). A request can carry an `EditorM` because the setup port is not the
  port `EditorM` runs over. After the root the editor runs its `setup` against
  a handler that collects its requests into a value, on the job thread.
  Nothing is registered until the editor thread installs that value, so a
  reload is all-or-nothing by construction, and a `setup` that throws is a
  program that ends in an error: the reload is rejected with its message.
  A new kind of registration is a new request.
- **One unchecked evaluation per reload.** The `setup` that runs is the
  constant `setup` the root itself declares. The adapter first requires
  that the root declares it, and then elaborates a trailer,
  `def «editor.setup» : Editor.SetupM Unit := _root_.setup`, so the
  elaborator checks it at the right type, and evaluates that one constant.
  A root that declares none is a diagnostic that says only the root's is
  run, also when a config file it imports declares one, which the
  diagnostic names; a `setup` of another type is an ordinary diagnostic;
  one that depends on `sorry` is an error value from the evaluation, and
  nothing runs. A config with no root has no trailer and registers nothing.
- **A command is the value `setup` registered**, not a name looked up in an
  environment. The registry holds the `EditorM` program, tagged with its
  owner, and running a command is running that program against the editor's
  port. Installing a reloaded config replaces the entries of the owner
  `config`; it never adds to them. Within one config a command name is
  registered once: a `setup` that registers a name twice is refused, with a
  diagnostic from `setup` that names the command, and the old config stays.
  The first of the two could never run, so it is a mistake in the config,
  and it is treated like a store declared twice. The number of commands a
  reload reports is therefore the number of names the config can be run by.
- **A package's commands are entries of the same registry**, for the owner
  named after the package, which a host registers when it starts, before
  any config ("Packages", below). A
  command is looked up by its name, and the latest entry of the name is
  the one found (`Config.State.command?`): config's command of a package's
  command's name runs in its place while it is registered, and the
  package's is found again once a reload drops it. The reload's report
  counts config's commands only.
- **A command may be given what it was called with**
  (`Config.Action.call`, handed a `Call`: the window it acts on, the
  invocation's arguments and its keys). `setup` registers one as such, in
  a package or in config, with `commandWith "greet" fun call => …`, a
  request of the setup port beside `command`, named as `jobWith` is
  beside `job` (built by the command loop's phase 10). A command
  registered with `command` is told nothing of its call. So a command of
  config's reads a count, and can be the command a prompt names, which
  receives the answer as its first argument; without it only a package's
  command could read an answer. The two kinds are commands under one set
  of names: a name registered with both is refused as registered twice,
  and a reload replaces them together.
- **A key binding is data too**: `bindKey "C-c t" "two"` in `setup` binds a
  key sequence to a command's name, tagged with its owner, and a reload
  replaces config's bindings as a set and never a package's. A
  sequence bound twice in one `setup` rejects the reload. Bindings are not
  counted in the report. A rejected reload changes no binding, so the
  packages' bindings, and config's of the last config that loaded, still
  run ([keymaps-and-modes.md](keymaps-and-modes.md), "Extending from
  config").
- **A mode is data too**: `defineMode { name := "listing", roles :=
  [(Role.nextItem, "bump")] }` in `setup` defines a mode (`Mode`,
  `lean/Editor/Mode.lean`), which the registry holds by owner, and a
  reload replaces config's modes as a set and never a package's. A
  mode name defined twice in one `setup`, and a mode with a role that is
  not registered, a suffix used twice or a suffix that is not keys, reject
  the reload with a diagnostic that names the mode and the problem. Modes
  are not counted in the report. The active keymaps are made from the
  registry for each key, so a reload's modes hold from the next key, and a
  buffer that had a mode a reload drops keeps its name, which then
  contributes nothing ([keymaps-and-modes.md](keymaps-and-modes.md),
  "Modes").
- **An ex name is data too**: `exCommand "greet" "greet-named" (takes :=
  .text)` in `setup` binds an ex name to a command's name, with what the
  name takes after it (`Ex.Binding`, `lean/Editor/Ex/Line.lean`). The
  registry holds ex bindings by owner, and a reload replaces config's as
  a set and never a package's, so config's binding of a shipped
  name runs in its place until a reload drops it. A name that is empty or
  holds white space, and a name bound twice in one `setup`, reject the
  reload. The command's name is not looked up until a line of that name
  is run. Ex bindings are not counted in the report
  ([keymaps-and-modes.md](keymaps-and-modes.md), "The ex command line").
- **A command asks for a reload.** `reloadConfig` sets a flag of the
  editor state, which the loop takes out after a command that ran to its
  end and hands back with the step; the host then feeds the reload
  reducer a request, as its driver's `reload` does. So the ex line
  `reload` is a command like any other, and the reducer's rules hold
  unchanged ([concurrency.md](concurrency.md), "Reload").
- **A job is the value `setup` registered, too**:
  `job "count" count fun n => …` registers a `Work`, the job with the
  handler that makes the command its result is taken to the editor with.
  The registry holds job entries by owner, apart from its command entries,
  and replaces them as a set. A job name is registered once in a config,
  like a command name; a job may have the name of a command. A job is not a
  command and is not counted as one: a config with one command and one job
  reports one command. `setup` starts nothing, and installing a config
  cancels the jobs of the one it replaces
  ([concurrency.md](concurrency.md), "Reload").
- **`setup` sets faces, as definitions**: `face "keyword" { foreground :=
  some (Color.rgb 200 0 0) }` sets the attributes it names of a face and
  leaves the rest. It is a registration, not a store: a store's value is
  config's own state, and a face is something the editor is told. The
  registry holds the definitions by owner, apart from the commands and the
  jobs, and an install replaces config's as a set. A name is set once in a
  `setup`; a face may have the name of a command. The theme is the theme
  in force followed by the installed config's definitions
  (`State.theme`), and a later definition of a name is over an earlier one
  by layout's rule, so a face config sets takes config's attributes over
  the theme's and one it stops setting is the theme's again. Lean merges
  nothing ([text-and-display.md](text-and-display.md), "Decorations", as
  built). A face is not a command and the reload report does not count it.
  The runtime that owns a display hands it the theme after a reload that
  installs and after a switch (`Config.retheme`): the host does, with its
  display's `setTheme`, which the recorder ignores.
- **Themes are named, and one is in force**: the `themes` package registers
  the themes that ship, `default` (the built-in theme) among them, and `setup`
  registers more with `defineTheme "name" theme` and names the one in
  force with `useTheme "name"`; the registry holds them by owner and an
  install replaces config's as a set. The theme in force is the reducer's
  state (`State.themeName`): an install whose config names a registered
  theme puts it in force; one that names none keeps it, so a theme chosen
  with `load-theme` survives a reload that does not name one; one that names
  a theme nobody registered keeps it and says so in the echo area, ``reload:
  no theme is registered as `<name>` ``, and on the report's lines
  (`theme: …`). `load-theme` switches it with no reload, through the
  reducer's `choose` event. Defining a theme name twice, or naming a theme
  twice, rejects the reload.
- **Segments of the mode line are named, and config lists them**:
  the `mode-line` package registers the shipped segments
  (`ModeLine.shipped`, `lean/Editor/ModeLine/Compiled.lean`), and `setup`
  registers more with
  `defineSegment "name" fun context => …` and lists each side's with
  `modeLine ["state", "buffer"] ["position"]`; the registry holds them by
  owner and an install replaces config's as a set. The listing in force is
  the reducer's state (`State.modeLine`), set at every install, so a
  config that lists none has the default order. A listed name nobody
  registered is left out and said, in the echo area after the unknown
  theme's sentence, joined by `; `, and on the report's lines
  (`segment: no segment is registered as `<name>``). The host resolves the
  listing over the registry for each step (`Headless.keys`,
  `Loop.Keys.modeLine`). Defining a segment name twice, or listing the
  mode line twice, rejects the reload.
- **Completion styles are named, and config chooses them by category**:
  the `completion` package registers the shipped styles, `fuzzy`,
  `orderless` and `path` (`Completion.Styles.shipped`,
  `packages/completion/Completion/Compiled.lean`, a default package since
  the features-as-packages roadmap's phase 4; a set without it matches
  with the core's own style, `Completion.Style.unregistered`), and
  `setup` registers more with `defineStyle`, chooses the default with
  `useStyle "name"` and a category's with `useStyleFor "buffer" "name"`;
  the registry holds the styles by owner and an install replaces config's
  as a set, and sets config's choices (`Registry.styleChoices`), so a
  config that chooses none has the fuzzy style for every prompt. A chosen
  name nobody registered leaves its category to the default and is said,
  in the echo area after the segments' sentences, and on the report's
  lines (`style: no completion style is registered under `<name>``). The
  host resolves the choices over the registry for each step
  (`Headless.keys`, `Loop.Keys.matching`;
  [keymaps-and-modes.md](keymaps-and-modes.md), "A prompt's matching
  styles"). Defining a style name twice, or choosing a category's style or
  the default twice, rejects the reload.
- **The frame padding is config's**: `framePadding 12` sets, in whole
  points, how far every window's text and its mode line's first and last
  fields are inset from its edges, and the bottom row at least (theming
  phase 6). It is the reducer's state (`State.framePadding`), set at every
  install, so a config that sets none has the editor's 8
  (`Loop.padding`), and the host hands it to the loop for each step
  (`Headless.keys`, `Loop.Keys.padding`): a reload changes it with no
  restart. Setting it twice rejects the reload.
- **The layout is config's**: `layout (.masterStack { share := 60, side
  := .right })` or `layout .monocle` chooses how the frame's windows are
  arranged, as a value with its parameters (window-management phase 1,
  `lean/Editor/Layout.lean`). It is the reducer's state (`State.layout`),
  set at every install, so a config that chooses none has the default,
  master-and-stack with main taking half on the left, and the host hands
  it to the loop for each step (`Headless.keys`, `Loop.Keys.layout`),
  whose publish has the frame choose it before the views are laid out
  when it differs from the layout the frame last chose (`Frame.chosen`,
  `Frame.choose`): a reload that changes it applies with no restart, and
  rearranges the same windows. A publish handed the layout it last
  applied leaves the frame's, so the window commands' changes (a zoom, a
  resized share, main's count, a split tree) last until config chooses
  another layout (window management's phase 2). A loop handed none keeps
  the frame's own. `layout Layout.manual` chooses manual splits; config
  writes only a shape, which is fitted to the windows. Any layout may be
  wrapped in edges, `layout (.edge .left 25 Layout.default)`, each giving
  the windows docked at its side a strip of its size in percent (window
  management's phase 3); a choice that drops an edge moves the windows
  docked there to the end of the tiled list (`Frame.choose`), so none is
  lost. Only config adds or drops an edge. Choosing it twice, a
  master-and-stack share above 100, an edge above 100 or a side given
  twice, at any depth (`Layout.problem?`), rejects the reload. It is
  chosen as a value, not by a registered name as a theme is, until a
  command switches layouts by name. With tabs (window management's phase
  5) the frame's own fields are the tab in view's, so a reload that
  changes config's layout rearranges the tab in view, losing none of its
  windows, and a new tab takes config's layout; the other tabs keep the
  layouts they had, and selecting one never applies config's layout to
  it, since `Frame.chosen` is frame-wide. Naming a tab's layout in config
  is deferred.
- **The tab bar is config's**: `tabBar .never` or `tabBar .always` chooses
  when the tab bar is shown (window management's phase 5,
  `lean/Editor/TabBar.lean`). It is the reducer's state (`State.tabBar`),
  set at every install, so a config that chooses none has the editor's
  own, shown while there are two tabs or more, and the host hands it to
  the loop for each step (`Headless.keys`, `Loop.Keys.tabBar`), whose
  publish sets it on the state (`EditorState.tabBarShown`). Choosing it
  twice rejects the reload.
- **Display rules are config's**: `displayRule { mode := some "notes",
  target := .edge .left }` adds a rule, in order, that says where a buffer
  a command makes is shown (window management's phase 3,
  `lean/Editor/DisplayRules.lean`). At install each rule is checked against
  the layout config chose (`DisplayTarget.missing?`): a rule whose target
  does not exist, an edge the layout lacks, is left out, its sentence is in the report
  (`Report.unusableRules`, a headless `rule:` line) and the echo area says
  it after an unknown theme's and the segments', as an unknown theme is
  reported; the config is installed without it. The rest are kept in the
  registry (`Registry.displayRules`), set at every install, so a config
  that makes none clears them, and handed to the loop for each step as
  `Loop.Registered.displayRules`, which answers a command's
  `RegistryRequest.displayRules` question (`BufferId.display`). Checking at install is
  enough because commands never add or drop an edge; a state handed a rule
  for an edge it lacks still places the buffer, in the stack.
- **The title bar is config's, at the next start**: `titleBar .standard`
  keeps the system's standard title bar in place of the themed one, whose
  paper is the theme's (theming phase 7). It is the reducer's state
  (`State.titleBar`), set at every install and published in the host's
  progress, which the window mode reads once, when it opens the window
  after the start-up reload: a reload that changes it takes effect at the
  next start. Choosing it twice rejects the reload.
- **The window's appearance follows the paper.** Once the window has
  opened, the reducer asks it for the light or the dark appearance that
  contrasts with the effective paper (`Config.Effect.appearance`,
  `Editor/Appearance.lean`), and afterwards only when a choice of theme or
  a reload changes whether that paper is light or dark. A rejected reload's first error
  is said in the echo area (`Config.Report.echo`), and its whole report is
  printed: on stdout in the headless mode, on stderr in the window mode.
- **The session runs no `IO` action from config.** A file is elaborated,
  `setup` is a program, a command is a program: every call from compiled
  Lean into config is a plain call of pure code.
- **A rejected reload reports diagnostics as data**: a source (the file's
  path in the config directory, `init.lean` or `Config/Keys.lean`, or
  `setup`, `config` or `base`), a line and a column of that file, a
  severity and a message. A file fails when it has an error; warnings and
  information are reported and do not reject. The config that was loaded
  stays, with its commands and its stores.

### Packages

A feature registers through one value, a **package**
(`lean/Editor/Package.lean`): a name and a `setup : SetupM Unit`, the
program config's `setup` is, written with the operations config uses. A
host registers features only from the packages it is handed. Built by the
packages roadmap's phase 2. How the executable finds its packages without
anyone listing the Lake packages (a package set, a generated root, an
entry-module convention, dependency order), what the core is, what a
package may import of it and which package each feature that was the
core's is are in [packages.md](packages.md), from that roadmap's phases 3
and 4 and the features-as-packages roadmap's. Beside the registrations of the kinds the core names, `Extension.add`
(`lean/Editor/Extension.lean`) is one generic registration: it registers a
value at the extension point of its type, which any package can declare,
and `Extension.values` and `Extension.named` read the values back typed
([extension-points.md](extension-points.md)).

```lean
def package : Package :=
  { name := "greeting"
    setup := do
      command "greet" (discard <| createText "hello")
      bindKey "C-c g" "greet" }
```

- **A package's owner is named after it** (`Package.owner`,
  `lean/Editor/Config/Packages.lean`). Everything its `setup` registers of
  the kinds an owner holds belongs to that owner: commands (plain, given
  their call, over a store), jobs, key bindings, prefix names, modes, ex
  names, faces, themes, segments, languages, compile contributions,
  completion sources, styles and displays, at-point sources and their
  uses, and menus. Its stores are cells of that owner, made when the host
  starts.
- **Packages register in list order, before config.** A host is handed an
  array of packages (`Headless.Collaborators.packages`) and, as its loop
  starts, registers each in the array's order
  (`Config.State.ofPackages`, in `Headless.Running.new`), before any
  config's `setup` runs. Of two packages that register one name, the
  later is the one a lookup finds. The array is the executable's generated
  root's: the packages of each Lake package of the set, each Lake package
  after the ones it requires, the core's first
  ([packages.md](packages.md), "The order packages register in"). Inside
  one Lake package nothing is ordered by what a package depends on: a
  command's name is looked up when it is run.
- **A reload leaves every package's registrations in place.** An install
  replaces the entries of the owner `config` alone
  (`Config.Registry.replaceOwned`), and cancels config's jobs alone, so a
  package's commands run when config fails to load and a package's job
  runs across a reload.
- **Config may replace what a package registered.** Config's entries come
  after every package's, and a lookup finds the latest entry of a name:
  config's command of a package's command's name runs in its place, and
  config's binding of a package's keys is the keymap's, until a reload
  drops them and the package's are found again. The same holds of a
  mode, an ex name, a theme, a segment, a source, a style, a display, an
  at-point source and a menu of one title.
- **A package's `useStyleFor` is a default**, the style of a category
  unless config's `useStyleFor` chooses another
  (`Config.Registry.styleDefaults`); config's `useStyle` does not reach it.
- **What is refused.** A package's `setup` is collected by the handler
  that collects config's, so it is all-or-nothing and refused for the same
  reasons: a name registered twice, a mode that cannot be meant, keys
  bound twice. A package is also refused when
  - its name is empty, is `config` or `compiled`, or is the name of a
    package earlier in the list (a second package of a name would replace
    the first's entries, and one named `config` would lose its entries at
    the first reload);
  - its `setup` sets what only config may choose: `useTheme`, `modeLine`,
    `framePadding`, `keyHintDelay`, `layout`, `tabBar`, `titleBar`,
    `autoReload`, `workspace`, `workspaceLister`,
    `projectLister`, `displayRule`, `shellTimeLimit`, `syntaxRefreshDelay`,
    `leaderKey`, `localLeaderKey`, `projectCommands`, `useStyle`,
    `useDisplay` and `useDisplayFor`, which an install sets for config and
    nothing holds by owner.

  A refused package registers nothing, is logged with its name (stderr in
  the executable, a line that starts `package: `) and is skipped: the
  others register and the editor starts.
- **The setup port grew to say what features register**: a job given as
  its work, whose finishing command is built from its arguments
  (`workJob`); an ex name's fixed arguments (`exCommand … (arguments :=
  …)`); keys given as values (`bindKeys`); and a menu of the menu bar
  (`defineMenu`), which the registry holds by owner and shows each title
  of once, as its latest definition (`Config.Registry.menuBar?`). An input
  scheme is not registered: it is the host's type parameter
  (`Headless.Collaborators σ scheme`), an `InputScheme` is in `Type 1`, and
  a setup request is plain data in `Type`.
- **The core's Lake package lists no package.** Every feature is a Lake
  package of the default set (`packages/`), each with an entry module that
  lists its `Package` values, defined in its `Compiled.lean`
  ([packages.md](packages.md), "A package's entry module", "The module
  map"). The core had an entry module of its own,
  `EditorCore.EditorPackage`, a library outside `lean/Editor/`, until the
  features-as-packages roadmap's phase 8 moved the last seven packages it
  listed out (`ex`, `frame-commands`, `menu`, `window-commands`,
  `tab-commands`, `restore` and `package-set`) and removed it. The
  default set registers its twenty-six packages in the order its lakefile
  requires them, those seven first, which keeps each kind of entry where
  the hosts registered it before there were packages
  ([packages.md](packages.md), "The order packages register in",
  "Registration order is visible"). Each package binds its own ex names:
  `ex` the files', its own and the buffers', `version-control` its twelve
  and `compile` its six, and the order those register in is the order the
  ex names' completion lists them in. The executable's root, which the
  package-set build generates, imports each entry module of the set
  and passes their arrays, appended, to `Editor.Main.run`
  (`lean/Editor/Main.lean`), with the names of the modules config is
  elaborated on, the set's base; `run` hands both to the headless mode and
  to the window mode (`Headless.main`, `Window.main`). An editor of the
  core alone is handed no package.
- **The lists are outside the host.** No module of a host imports an
  entry module or a module that defines a package: the host's modules are
  every module the generated root imports other than the entry modules,
  with what they import, and none of them is an entry module or a module
  one imports directly, a reviewer rule
  ([structure.md](../../.agents/rules/structure.md), "Host imports"). The
  rule is of the modules that define packages. No core module can import
  one: every feature is a Lake package the core does not require, so Lake
  itself refuses the import, and the core's root reaches every core module
  ([packages.md](packages.md), "The core's root").
- **The owner `compiled` registers nothing in a host.** It remains as the
  owner of what the core falls back to when no package registered it: the
  fuzzy style and the minibuffer display of a registry that holds none.

Pinned by `ModelTest.packageChecks` and `ModelTest.registryChecks` (what
the core falls back to with no style or display registered), on the
models, with each default package's own checks of what it registers, and
by `ConfigTest.hostChecks` and `ConfigTest.hostLoopChecks`, through the
headless host.

### One shared state

Interpreted config and compiled code see the same values. In the spike,
compiled code wrote to a global reference and config read it, config's key
binding appeared in the compiled keymap, and a module's initialiser ran
once. This needs `supportInterpreter`, `enableInitializersExecution` before
the import, and `importModules (loadExts := true)`. Every other combination
failed loudly instead of producing a second copy.

As built (`lean/Editor/Config/Elaborate.lean`):

- **The base is made once per process and grown, never made again.** The
  first reload job imports the set's base from the directories it is
  given, searched in order: the `.olean` directories of the Lake packages
  whose modules the base holds, the core's first, and then `lib/lean` under
  the toolchain's. A base module in none of them fails the import, naming
  the module (`ConfigTest.elaboratorChecks`). Not Lean's `initSearchPath`,
  which also reads `LEAN_PATH` from the environment. The adapter keeps
  Lean's import state with the base, and a reload whose files import linked
  modules the base does not hold reads those into it, each module file
  once, and makes a new environment over the old imports and the new
  (`Lean.importModulesCore` on the retained state, then
  `Lean.finalizeImport`). A second import of the same modules in one
  process about doubled its resident memory in a prototype, which is why
  the state is kept and grown.
- **The import runs no initialiser of a linked module.** Lean looks for a
  module's native initialiser first, and interprets a module's `initialize`
  declarations only when there is none. Each root that links the adapter
  imports `Editor` at compile time beside it (the editor's generated root,
  which imports the rest of its base too, the entry modules of the set's
  packages; `lean/ConfigTest/Check.lean`;
  `lean/FfiTest/Editor/Window/Real.lean`),
  so every module of the base is linked into any executable that can
  elaborate config, and its initialiser ran once, when the process
  started. The adapter itself does not import `Editor`: it is a core
  module, and the base imports features that are not the core's. Every
  root that reaches the adapter reaches `Editor`
  ([structure.md](../../.agents/rules/structure.md), "Core imports";
  [packages.md](packages.md), "The core's root"). This matters twice: Lean documents initialiser execution as
  unsafe beside other threads, and the editor thread is running during the
  import. A third-party package loaded as interpreted modules would run its
  `initialize` code at import, on a job thread; that is part of the open
  question on packages.
- **Config's own code is pure**, so the state it shares with compiled code
  is what it registers and what its commands are handed: the registry, the
  store cells and the texts all live in compiled Lean. The mechanism itself
  is checked on its own: `config-test` links a fixture module with an
  initialised reference, has compiled code write to it, imports the base,
  has config write to it, and reads it back from compiled code. Each side
  sees the other's write, and the import did not reset the reference.
- **Config cannot name a binding.** `Editor` never imports `Editor.Ffi`, so
  a file that mentions a binding is rejected as an unknown identifier, and
  one that imports the binding's module is refused at the import: the base
  does not hold it (both checked by `config-test`).
- **Config may not declare `initialize`.** Such a file elaborates, but the
  interpreter throws a C++ exception the first time a declaration that
  reads the constant is evaluated, and the process aborts. This one can be
  refused before any code runs, so the adapter rejects a file that adds an
  `initialize` declaration, with a diagnostic that points at the store,
  which is where config keeps state. It is also what keeps an import of a
  config file's module data from running an initialiser.

### An exception from the interpreter ends the process

Deep recursion or a missing native symbol in interpreted code raises a C++
exception that Lean's `try`/`catch` does not see, and the process aborts.
That is left as it is. A call from compiled code into config (running a
command, a handler, a job, `setup`) is an ordinary call with no guard around
it, and the glue has no C++, no terminate handler and no signal handler.

Only a C++ `try`/`catch` could stop the exception, and it could not restore
the state from before it. The compiled Lean frames the exception passes
through are C, so they release nothing: references leak, and `finally`
blocks and lock releases do not run. A crash is safer than carrying on in
that state.

The interpreter's check fires only once its thread's stack is full, so the
stack's size is how long a runaway recursion in config runs before it ends
the process. Lean's default for each thread it creates is 1 GiB. **Every
thread Lean creates in the editor has a 64 MiB stack** instead: Lean's main
thread, dedicated tasks and the pool, so every thread that runs config or
elaborates it.

- **How it is set.** The entry point (`editor_entry` in `lean/ffi/glue.c`)
  calls the runtime's `lean_internal_set_thread_stack_size` before it starts
  Lean. The size is one process-wide value that Lean reads each time it
  creates a thread, and Lean adds 128 KiB to it. `lean.h` does not declare
  the function; Lean's own `lean` binary calls it. A toolchain that renames
  it fails the link.
- **Not through the environment.** `LEAN_STACK_SIZE_KB` set in the editor's
  own environment would be inherited by every child process, and a Lean
  language server started from the editor would get 64 MiB threads.
- **A user can change it** with `LEAN_STACK_SIZE_KB`: Lean reads the variable
  when its `main` starts, after the entry point has set the default. The
  editor adds no setting of its own.
- **Why 64 MiB.** Measured in a prototype, with recursions that returned:

  | | 16 MiB | 64 MiB | 1 GiB (Lean's default) |
  |---|---|---|---|
  | Interpreted frames before the stack check fires, at the 832 bytes a frame measured | about 20,000 | about 80,000 | about 1.29 million |
  | Time to recurse that deep | 3.7 ms for 19,000 frames | 14 ms for 70,000 frames | 191 ms for 1,000,000 frames, with resident memory up by about 950 MB |
  | Nesting depth of source the parser survives, at the 3.9 KB a level measured | about 4,000 | about 16,000 | |

  The deepest stack the elaborator used was 6.2 MB, on input it then
  rejected with "maximum recursion depth has been reached"; a config of 50
  definitions and a `simp` proof used 78 KB. So 64 MiB is ten times the
  elaborator's worst case, and a runaway recursion in config ends in about
  15 ms having touched 64 MiB instead of a gigabyte. 16 MiB would abort
  sooner, but leaves 2.6 times the elaborator's worst case and aborts honest
  recursion a quarter as deep; an abort ends the session, so the larger of
  the quick sizes is chosen.
- **What it costs.** Honest deep recursion is fatal sooner than under Lean's
  default: a config function that recurses 80,000 frames without a tail
  call aborts the editor where a gigabyte would have let it finish.

`ffi-test` checks the size on each kind of thread (`FfiTest.entryChecks`,
in the gate); a thread reports its own stack size, so the check aborts
nothing. `mise run ffi-overflow` shows the abort itself, under that size
(the `overflow` scenario of `lean/FfiTest/Editor/Ffi/MainThread.lean`). It
is run on demand and is not part of the gate, because every abort makes
macOS write a crash report on the machine.

## The editor API is an interface

Commands and jobs are written against interfaces, not against the library
bindings. Each interface has two implementations:

- **The real one**: calls the Rust library.
- **The model**: a pure Lean structure that behaves the same way (text,
  selections, a queue of pending effects). No Rust involved.

This is ports and adapters in Lean, and it gives:

- Lean tests that run under `lake test` without the Rust library.
- Theorems about commands, stated against the model: `x` then `u` restores
  the buffer; a permission policy only ever answers with an option the
  agent offered.
- The effect split from [concurrency.md](concurrency.md) enforced by
  types: `EditorM` has no blocking operations, `JobM` has no mutating ones.
- A contract check per interface: one suite of properties run against both
  the model and the real bindings, so the model cannot drift from Rust.

### An interface is a port, and a command is a program over it

Decided 2026-11-11, from prototypes of both candidates: a free-monad program
type with two interpreters, not type classes with commands polymorphic over
the monad.

- A **port** is a type of requests and, for each request, the type of its
  reply. A **program** over a port is plain data: it is finished, or it
  makes a request and continues with the reply. `EditorM` is the type of
  programs over the editor's port, a composite of the text, display and
  watch ports and the requests about the editor state ("The editor's port
  is a composite", below), and `JobM` the type of
  programs over the job port. Both are ordinary monads, and a command reads as a `do` block.
- A port has two **handlers**. The model is a pure function from a request
  and the model's state to a reply and a new state. The real binding answers
  each request with a call into the Rust library. One runner for each kind
  of handler runs any program, so the same command source runs against both.
- The contract check is a list of commands that both run.
- A theorem about a command is stated about its run against the model and
  proved from the port's lemmas.

The program type is indexed by a request type with a reply type per request.
It is not the textbook free monad over a functor, which lives in `Type 1`.

What decided it:

- **Config is evaluated at one concrete type**, and `EditorM α` is that
  type: it is the type the model runs too. With classes the concrete type is
  the real monad, over `IO`, and a command written at it cannot run on the
  model or appear in a theorem. One that can has a type in `Type 1`, which
  `evalConst` refuses, as it does the textbook free monad. A value in
  `Type 1` also cannot be the result of an `IO` action or sit in a
  reference.
- **The split is checked without any discipline.** A program holds no `IO`,
  so there is nothing to smuggle in: a text request in a job, a job in a
  command, and `IO` in either are type errors. With classes the concrete
  command monad would also need a private constructor, or a bare function
  over `IO` is accepted as a command.
- Both read the same in `do` notation, both state theorems against the
  model with the same proofs, and both are clean under every linter.

What it gives up:

- **Direct calls on the real path.** Each request allocates a program node
  and its continuation and goes through the runner: several times the cost
  of a direct call, tens of nanoseconds more, against the 6 to 12 µs a key
  takes. Binds nested to the left cost in proportion to their depth. That
  the cost stays small is assumed, not measured in the editor.
- **Library handles as values in the interface.** A request is plain data,
  so a text or a snapshot is named by an id and the real binding keeps the
  tables from ids to handles. A text or a snapshot lives until a command
  releases it or the table is dropped, not until the last Lean reference
  goes: a snapshot a command takes and does not release stays in the table.
  A released id is refused for good, and an id is never used again.
- **A subscription as a thing the store holds.** A consumer that follows a
  text's edits is not registered anywhere: a subscriber is a revision the
  caller keeps and asks from again. So no request makes or releases one,
  and a caller that loses its revision has lost its place: it reads the
  text whole and starts from the revision it has then.
- **A request that carries a program over its own port** (a key binding
  made from inside a command): the port would refer to itself. Registration
  from a later port type-checks, and that is what the config session does:
  `setup` is a program over a port of its own. A job's result handler needs
  neither that nor a program type written for the editor: a job finishes
  with a command, the handler already applied to its result, so the type of
  the result stays inside the job and no request carries a handler.
- **A command's type no longer lists the capabilities it uses.** Every
  command has the whole port.

Set aside: a concrete `EditorM` that reads a record of operations over `IO`
(the model's state is then behind a reference, so no theorem about a command
can be proved). Left open as a later step, if the runner's cost becomes a
measured problem: classes for compiled commands, with the program type as
the instance config uses. Commands written at `EditorM` would not change.

The pattern is built for one deliberately small interface, text:

| Piece | Where |
|---|---|
| Programs, and the two runners | `lean/Editor/Program.lean` |
| The text port: create, insert, delete, read; `snapshot`, which takes a text as it is now; `ask`, which puts a question to a text or a snapshot (its revision, length, row count or contents; the point of an offset and the offset of a point, in bytes, in UTF-16 or in cells; the content of one row and the text of a range; and where a motion leads from a position, with the motion a value of an inductive, so that a new motion is a constructor and not a question); `release`, which gives either up; `apply`, which applies a transaction, built by a command as plain data, with an origin, and replies with the revision it produced; `log`, which puts a question to a text's edit log (what changed since a revision, as one patch; who wrote a range); `forget`, which moves where that log starts; and `mark`, `marker`, `place` and `unmark`, which have a text hold an anchor or a selection that every edit moves, read it back, put another in its place, and give it up; and `applyInverse`, which applies the inverse of a run of a text's revisions as one edit, where the text is in the state the run ended in, and replies with the revision it produced and the selection to place, and `dropInverses`, which drops the inverses a text keeps for a run; `copy`, which makes a new text of what a text or a snapshot holds, at revision 0 with an empty log, no markers and no kept inverses; and `adopt`, which takes into the store a snapshot a job held, named by a second kind of id (`JobSnapshotId`) and answered from what the command's run was handed, so that an id the run was not handed is refused. `ask` also carries what a selection covers. A new question is data, a constructor of the query, not a request | `lean/Editor/Text.lean` |
| Its pure model: a string and a revision for each text, a snapshot as a copy of that pair, and points found by walking characters. A transaction's changes are applied as the ranges they change. The log is modelled beside the texts, not inside them, as who wrote every byte and the text at every revision, so the model finds a patch and a trace by a different route from the library's. Markers are a table beside the texts too, moved through the ranges an edit changed, and what a selection covers is read off the string's rows and characters. A motion is picked from a list of every cell start or every word of the string, where the library walks from the position; and two theorems are stated about the conversions, that one that answers is undone by the other and that the line start of a line start is itself. The model keeps no inverse: beside the texts it keeps, for each, the name of the state it was in at every revision, the selections each edit carried and which inverses were dropped (its history). The text an inverse leaves is read off the log's model, and what it changed is the gaps between the bytes the two states share, by the identities the bytes had when the run ended; the library composes the inverses it kept. What a job held reaches its command as a value the run is handed, which `adopt` reads | `lean/Editor/Text/Model.lean` |
| Its real binding, over the text-storage crate (`editor-text`): a table of documents and one of snapshots. The snapshots are a table behind a reference that the binding publishes and alone writes, in a command, on the editor thread; a reader off that thread is given its read half and nothing else. The documents are a value the editor thread owns. A run of a finished job's command is handed the library's snapshots the job held. A question about a text is answered from a snapshot taken for it; a transaction, a question about the log and a marker go to the document, which holds the markers: the binding keeps no table of them, and a marker's id is its text's id with the document's number for it, so that a text refuses another's. The kept inverses are the document's too, with no table here: a run is two of the text's own revisions. A transaction, a patch, a trace, a marker, extents and what an inverse did are lists, which cross the boundary as words, a buffer of 64-bit numbers that a codec on each side writes and checks | `lean/Editor/Text/Real.lean`; in `lean/Editor/Ffi/`, `Document.lean`, `Snapshot.lean`, `Transaction.lean`, `Log.lean`, `Marker.lean`, `Inverse.lean` and `Words.lean` |
| Its contract, run against the model by `lake test` (`mise run lean-test`) and against the real binding by `contract-test` (`mise run ffi-test`) | `lean/Editor/Text/Contract.lean` |
| A command, `append`, with a theorem about it | `lean/Editor/Command/Append.lean` |
| The undo tree: logic above the port, in plain Lean that imports the port alone. It is told the text's revision, sets the boundaries of groups, undoes, redoes and moves between branches by `applyInverse`, drops what it has crossed by `dropInverses`, reverts the open group, and tracks the state last saved, with a theorem that a boundary does not change whether a text is modified | `lean/Editor/UndoTree.lean` |
| Its cases, one list of the text contract's kind of property, run against the text model by `lake test` and against the real binding by `contract-test`: the first logic above a port that runs on both | `lean/Editor/UndoTree/Cases.lean` |
| `JobM`, and the compile-time checks of the split | `lean/Editor/Job.lean` |

The job port is the second interface built this way, and the first whose
real implementation is not one call a request:

| Piece | Where |
|---|---|
| The job port: a clock and a wait; `sleep`; `Timer`; the file requests, `File.load`, `File.save`, `File.stamp` and `File.list` (a directory's entries, sorted by name, each with its kind), whose replies are a result or a refusal, a value; the file-watch requests, `FileWatch.start`, which watches a file, a directory's entries or a directory's tree and replies with the watch, named for the job, or a refusal, and `FileWatch.next`, which waits for the watch's next delivery; `Work` | `lean/Editor/Job.lean` |
| The file requests as data: a stamp, line endings and the dominant one, what a save expects, a save's source (a snapshot a command took or one the job loaded), what a load answers, a directory's entry and its kind, and the refusals with what each says | `lean/Editor/File.lean` |
| The pure model of the files a job reaches: directories, files with their bytes and stamps, a count of writes for a clock, the snapshots the editor published and those the job's loads made. It answers by the library's rules and its own route: a file's text is decoded a character at a time, each byte that starts no valid character becoming its escape | `lean/Editor/File/Model.lean` |
| The file-watch requests as data: a target (a file, or a directory, recursive or not), the coalescing (a window and a bound, the job's policy, with no default), the watch's id, a change (an absolute path and its kinds: created, written, renamed, removed, missed) and the refusals with what each says. The module docs carry the rules and where an addition goes; a `stop` request is listed there as not built. It imports nothing. It is not the interrupt flag's port, `lean/Editor/Watch.lean`, which is `Watch`: this one is `FileWatch` | `lean/Editor/FileWatch.lean` |
| The pure model of what a job's watches see: the directories there are, the watches with their changes recorded, what each command a test expects changes on disk, and the watches ended. It routes a change as the library's service does, records it by the library's coalescing rule, bound and collapse included, and answers a `next` at the window from the first change, moving the clock there | `lean/Editor/FileWatch/Model.lean` |
| Its pure model: a clock, the instant the job is cancelled at, the model of files, the model of processes, and the model of watches, which a command a job runs touches when the run ends | `lean/Editor/Job/Model.lean` |
| Its contract: the clock's properties, run against the model and against the runner over the fake clock by `lake test`, and against the runner over the timer service by `contract-test`; and the file properties, each the files to start with, a job, and every file that must be there afterwards, run against the model and the runner over the fake file service by `lake test`, and against the runner over the library's file service, on real files in a temporary directory, by `contract-test` | `lean/Editor/Job/Contract.lean` |
| The runner, on plain tasks and promises: the table of waits, the clock port and the file port (`Files`), `spawn`, cancellation, and what a job holds: the snapshots its loads made, which a job's handle lists, which no other job can save, and which `settle` releases | `lean/Editor/Job/Runner.lean` |
| The clock port's fake, which a test moves by hand, and the file port's (`FakeFiles`): the model of files behind a reference, whose completions and takes a test can hold; the fake completion pump (`FakePump`), the one step point the job services' fakes answer through in their step mode (`FakeAnswer.onStep`), and its stepped runner (`FakePump.runToEnd`); the fake scheduler (`FakeScheduler`), which runs a job's code on the check's thread when it is stepped | `lean/Editor/Job/Fake.lean` |
| The scheduler port (`Scheduler`, `Services.scheduler`): where the runner runs a job's start and its continuations, Lean's task pool for every host (`Scheduler.pool`). Its contract, run over the fake and over the pool by `lake test` | `lean/Editor/Job/Runner.lean`, `lean/Editor/Job/SchedulerContract.lean` |
| The completion pump's port (`CompletionSource`, a pull of a completion, quit or something else) and the pump over it (`pumpFrom`); the library's source is `librarySource` in `Real.lean`. Its contract, run over the fake pump by `lake test` and over the library's completion queue by `contract-test` | `lean/Editor/Job/Pump.lean`, `lean/Editor/Job/PumpContract.lean` |
| The session journal's port (`Headless.Journal`), its real adapter over the file service (`Journal.real`), its recording fake (`RecordingJournal`), and its contract, run over the fake by `lake test` and over the real journal by `contract-test` | `lean/Editor/Headless/Journal.lean`, `lean/Editor/Headless/Journal/Real.lean`, `lean/Editor/Headless/Journal/Fake.lean`, `lean/Editor/Headless/Journal/Contract.lean` |
| The fake of the syntax service's deliveries (`FakeSyntaxService`), the questions' answers the model's, and the delivery contract, run over the fake by `lake test` and over the real binding by `contract-test` | `lean/Editor/SyntaxTree/Fake.lean`, `lean/Editor/SyntaxTree/DeliveryContract.lean` |
| The clock port over the Rust timer service; the file port over its file service (`realFiles`), which keeps what a load made for its job (`HeldSnapshots`) and reads a snapshot a command took through the read half of the published table; running a finished job's command with what the job held handed to it, then settling the job (`finishWith`); and the completion pump | `lean/Editor/Job/Real.lean` |
| The cases that cross the text port and the job port: a command, a job, the job's command and a last command, played on the two models by `lake test` and on the real binding and the file service by `contract-test`. A file a job loads becomes a text, and a save that reports late marks the undo tree's state it wrote | `lean/Editor/File/Cases.lean` |
| The job table, pure, and the shell the editor thread calls | `lean/Editor/Job/Table.lean`, `lean/Editor/Job/Jobs.lean` |
| Warming the pool | `lean/Editor/Job/Pool.lean` |

The display interface is the third. Its real binding is not built here: it is
the display pipeline's, which holds it to the same contract:

| Piece | Where |
|---|---|
| The scene, plain data published after a command: views by handles (a snapshot, markers), faces by name, the echo text, the pending prefix and the preedit | `lean/Editor/Scene.lean` |
| The display port: `publish` a scene, and two layout queries answered in the same call, the rows a view shows from its anchor (`rowsShown`) and the position some visual lines away with the goal x passed back (`linesFrom`); `DisplayM`; the cell size the contract runs at (`Display.Cells`) | `lean/Editor/Display.lean` |
| Its pure model: the scenes published, in order, and a layout in fixed-size cells, in which a tab reaches to the next multiple of 8 cells and a wide character is two, for tests, and for the recorder below | `lean/Editor/Display/Model.lean` |
| Its contract, imported from the port alone: properties of the two queries at a cell size, run against the model by `lake test` at two sizes, against the recorder over the library's snapshots by `contract-test` at the same two, and to be run against the real binding over a fake shaper whose glyphs have that size | `lean/Editor/Display/Contract.lean` |
| The display where there is no window (the headless host): a recorder that keeps the last scene published and how many have been, and answers the two queries with the model's layout rule over the text of the library's snapshot, read through the published table's read half. It is the one place the model's rule runs outside a test, because a host with no window has no layout to ask; an editor with a window asks the real binding every time | `lean/Editor/Display/Recorder.lean` |
| The events of the editor queue as plain data (a key with its logical and physical identity and modifiers, a pointer, a resize, files to open), and the one module that reads and writes their layouts on the queue | `lean/Editor/Event.lean`, `lean/Editor/Event/Queue.lean` |

The runner is the job port's real handler. It is not a function from a
request to an `IO` reply, as the text port's is, because a job must hold no
thread while it waits: the runner answers a wait by registering a promise
and chaining the rest of the program on it
([concurrency.md](concurrency.md)). The model runs the same program to its
end in one call, with the clock moved by each wait.

That a wait is not a command is checked when `lean/Editor/Job.lean` is
compiled: a wait offered at `EditorM Unit`, or at `TextM Unit`, is a type
error, alone and after a text request in a `do` block. So "a command may not block" is pinned
beyond `IO`. Each of the two checks was seen to bite once by hand: offered
at `JobM Unit`, where a wait is legal, the module stops building. The same
module checks that a file request is a job and not a command, and that
`adopt` is a command and not a job: the one request that writes the text
store from what a job made cannot be written in a job. Each of those was
seen to bite once the same way.

A file request is the first request whose wait has a reply. A completion
says only that a wait is over, so the runner fetches the reply from the
service afterwards, on the job's thread, and never for a job that was
cancelled.

### The editor's port is a composite

Decided 2026-11-13, by the command loop's phase 2; the state requests were
added by its phase 8. A command reaches the text, the display, and the
editor state's buffers and windows through one port, whose shape is:

- **Its requests are a sum of sub-ports**, one constructor a sub-port:
  `EditorRequest.text` carries a request of the text port,
  `EditorRequest.display` one of the display port, `EditorRequest.watch`
  one of the watch port, `EditorRequest.clipboard` one of the clipboard
  port, `EditorRequest.fuzzy` one of the fuzzy port,
  `EditorRequest.syntaxTree` one of the syntax tree port,
  `EditorRequest.state` a request about the editor state,
  `EditorRequest.registry` a question to the registry and config, and
  `EditorRequest.control` a request to end the running command or to run
  something registered inside it: nine sub-ports. The reply to each is its sub-port's reply. `editorPort` is
  an `abbrev`, as every port is.
- **The fuzzy port** (`lean/Editor/Fuzzy.lean`, added by the command
  loop's phase 14) is what the editor asks of a fuzzy matcher:
  `rank pattern candidates` answers the indices of the candidates the
  pattern matches, best first, each once. It refuses nothing.
  - **What matches** is one rule: the pattern's Unicode scalar values all
    occur in the candidate, in order, with case kept. A Lean `String` is
    a list of scalar values, so the model (`FuzzyModel.matches`) is a
    subsequence test and needs no table. That is what lets the model and
    the library agree on every input
    ([rust-library.md](rust-library.md), "Fuzzy matching, as built").
  - **The order** an asker may rest on is one thing: a candidate that is
    the pattern is first. After those the model's order is the
    candidates' own and the binding's is the library's scores.
  - **The contract** (`lean/Editor/Fuzzy/Contract.lean`) asks those two
    things and no more: which candidates match, on a table of cases
    compared with the reply sorted, and that an exact match is first,
    which reads the first index only. `lake test` runs it on the model
    and `contract-test` on the real binding. **The known gap**: the two
    are not held to agree on the order past the exact matches. So logic
    above the port is tested on the model, and a check of it computes
    what it expects with `FuzzyModel.rank` and never writes an order out.
  - **How the two sides are held together.** The Lean model and the Lean
    binding by this contract. The Rust fake and the library's adapter by
    the Rust port's contract, which also sweeps generated texts. The
    binding is the Rust ranking rule over that adapter. So the model
    cannot drift from the library without one of the two contracts
    failing.
  - **As a sub-port**: `Fuzzy.rank` is used in a command as it is, and
    config can call it. On the models it is answered by the fuzzy model,
    which has no state, and moves the watch model's clock, as every
    request that reaches the library does. Against the library it is
    answered by `Fuzzy.real`, one call, as a text request is by the text
    binding: the matcher needs nothing a host could hand in, so no runner
    takes a handler for it and no host changed. It is guarded like any
    request the loop does not answer in place.
  - Set aside: a function handed to the loop. The loop's publish and a
    command would then reach the matcher two ways, and config not at
    all.
- **The syntax tree port** (`lean/Editor/SyntaxTree.lean`, made a sub-port
  by the syntax roadmap's phase 2) is what a command and a major mode ask
  of the library's syntax service: grammars, attaching and detaching a
  text, queries, a grammar's shipped query, drawing a text with a query's
  captures in faces, its injections and the languages they may name, and
  keeping a query of a structural kind (text objects, indents) whose
  captures are asked by kind (made by the syntax roadmap's phase 3). **Its refusal is a value**: `SyntaxTree.lift`
  runs a syntax tree program in a command and hands back its `Except
  SyntaxTreeError`, which the command matches on, as the clipboard's is, so
  the editor's error type is not widened. Its result type is not the
  program's, so it is no `MonadLift` instance and a command calls it by
  name. On the models it is answered by the syntax tree model, whose texts
  are filled from the text model's snapshots and which tells two snapshots
  of one text from two texts by the text each was taken of, and each
  request moves the clock by a pace. For real it is answered by the
  handler a runner is handed (`SyntaxTree.none`, with no grammars, by
  default): a host makes one over the table of snapshots its text binding
  publishes, once as its loop starts (`Collaborators.syntaxTree`,
  `Running.syntaxTree`), and hands it to every command it runs, a finished
  job's through `Job.finishWith` too. A syntax tree request is guarded like
  any request the loop does not answer in place, and what it did is not undone on
  rollback: the library parses and draws outside the editor state. What
  setting a major mode with a syntax tree asks of it is
  `lean/Editor/Highlight.lean`'s ([keymaps-and-modes.md](keymaps-and-modes.md),
  "A buffer's modes").
- **The clipboard port** (`lean/Editor/Clipboard.lean`, added by the
  command loop's phase 13) is what a command asks of the system
  clipboard: the text it holds, and to hold another. The clipboard is
  outside the editor, written by other programs and not rolled back with
  a command, so it is a port and not editor state. **Its refusals are
  values**: a clipboard may not be there, and each request is then
  answered `unavailable`, an `Except` in the reply, as a state request's
  refusal is. Nothing is thrown, so a clipboard program has no error of
  its own (`ClipboardM`) and the editor's error type is not widened. It
  has a pure model (`ClipboardModel`, which a test can take away), a
  contract every implementation runs, and a stand-in for a host with no
  window, a cell of the process that answers with the model's rule
  (`Clipboard.InProcess`), which is the display recorder's twin. The
  adapter to a window system's clipboard is the display pipeline's, and
  runs the same contract when it is bound. A clipboard request is guarded
  as a text request is, and moves the watch model's clock.
- **The watch port** (`lean/Editor/Watch.lean`, added by the command loop's
  phase 6) is what the loop watches a command with: whether the interrupt
  flag is up, lowering it once, and the job clock in milliseconds. It is a
  sub-port, and not checked by the host, so that the loop stays one pure
  program that runs the same on the models and against the library: the
  loop asks the flag before each request of a command it runs
  ([concurrency.md](concurrency.md), "Foreground: commands"). A flag check
  inside each handler could not say "stop" for a request whose reply has
  no refusal, and a host that ran a step in pieces would be a second
  driver for the models that could drift. The clock is here and not in a
  sub-port of its own because each sub-port costs a constructor, an
  embedding and a case in each runner. Nothing on it is refused. It has
  nothing to do with watching files, which is the job port's `FileWatch`
  (`lean/Editor/FileWatch.lean`), named so that this port keeps its name.
- **A command is `EditorM := ExceptT TextError (Program editorPort)`.** A
  program over the text port alone is `TextM`, and every text operation and
  all logic over text alone (the undo tree, the text contract, `append`)
  stays at it; the display's is `DisplayM`, the watch port's `WatchM` and
  the clipboard's `ClipboardM` and the fuzzy port's `FuzzyM`.
  `TextM.lift`, `DisplayM.lift`, `Watch.lift`, `Clipboard.lift` and
  `Fuzzy.lift` embed each in a command,
  and they are `MonadLift` instances, so an operation of any sub-port is
  used in a command as it is. That is why every config source and fixture written before the port
  became a composite elaborates unchanged. There is no lift from `JobM`, so
  a job is still not a command, which `lean/Editor/Job.lean` checks at
  `TextM` and at `EditorM`.
- **A refusal is a `TextError`.** The display's two refusals mean what the
  text port's of the same names mean (a snapshot that names nothing, an
  offset that is not a position), so the display's lift maps each to its
  namesake. Widening the error to a sum now would break every config that
  throws a text refusal, and nothing needs it yet. The first sub-port whose
  refusal has no `TextError` counterpart widens it, in its own phase. The
  state requests did not: what the editor state refuses (a window that
  would be the last, a buffer a window shows, a mode or a job no one
  registered) is a **value**, an `Except` in the request's reply, which a
  command matches on. Nothing is thrown for it, so a command's error is
  still a `TextError`, and a layout operation's refusal keeps its type.
- **A runner's state is the product of its sub-ports' states**, but for
  the editor state, which is the loop's (below). On the
  models it is the text model, the display model, the watch model and the
  clipboard model side by side (`EditorModel`); before each display request the display model's
  texts are filled from the text model's snapshots, so a command that takes
  a snapshot and asks the display about it is answered from that
  snapshot's text. On the models time passes only with requests: the watch
  model's clock moves on by its pace at each text and display request, and
  a test has an interrupt key arrive at a command's n-th request. For real
  it is the text binding's table, with a display handler (`DisplayHandler`)
  passed in: the recorder in a host with no window, the display pipeline's
  binding in one with a window; and a watch handler (`WatchHandler`),
  `Watch.real` over the library's flag and the job clock in a host, and
  `Watch.idle`, never interrupted, by default; and a clipboard handler
  (`ClipboardHandler`), the in-process clipboard in a host with no window,
  and `Clipboard.unavailable`, which answers every request so, by default.
- **The state requests are the loop's to answer.** Built by the command
  loop's phase 8 (`lean/Editor/State/Request.lean`,
  `lean/Editor/Command/Dispatch.lean`). A state request's handler is one
  pure function over the editor state (`EditorState.handle`), as a store
  is: no Rust, no model and no contract check. This section first had both
  runners' state gain the editor state. What was built instead: the
  command loop keeps holding the editor state, and answers the state
  requests of each command it runs in place, by a pure transformation of
  the command's program (`EditorM.dispatched`), before the program reaches
  a runner. The reasons:
  - the loop is the one writer of editor state
    ([concurrency.md](concurrency.md)), and stays so;
  - rolling a failed command back stays "keep the state from before it";
  - the handler is the same function on the models and against the library
    by construction, since it runs above both runners;
  - the loop, and every test that builds one, is as it was.

  The registry's questions (`lean/Editor/Command/Registry.lean`) and the
  control requests (`lean/Editor/Command/Control.lean`) are the loop's to
  answer in the same way, and for the same reasons: a question is answered
  by one pure function of what the loop was told of the registry and
  config (`Loop.Registered.answer`), and a control request by ending the
  command's program or putting a registered program before its rest. So
  neither has a model, a contract or a binding.

  A runner still answers every request of the port. Each answers a state
  request that reaches it as an editor with no buffer and no window would
  (`EditorState.none`), a question as with nothing registered
  (`RegistryRequest.bare`) and a control request with nothing run and
  nothing ended (`ControlRequest.bare`), and keeps nothing: a command run
  where no loop dispatched it finds nothing. Every command a host runs goes through the
  loop; only a test runs one bare. A split of the port into one for
  commands and a smaller one for runners, which the types would then check,
  was set aside: it would rename the loop's monad and every call that runs
  a command on the models.
- **A request holds plain data.** A state request names a mode and a job;
  it cannot hold the mode's on-enter action or the job, which are programs
  over this port ("A request that carries a program over its own port",
  above). The loop is told what the names stand for (`Loop.Registered`,
  made by the host from the registry for each step), and answers those two
  requests with it: it refuses a name no one registered, runs a mode's
  on-enter actions inside the command, and hands the jobs a command asked
  for back to the host to start. A control request names the command, the
  source or the style it runs, and a question's reply is names and
  settings, never a program.
- **Where it grows.** A new request about the editor state is a constructor
  of `StateRequest` and an operation of `lean/Editor/State.lean`
  (`lean/Editor/State/Request.lean`, "Where an addition goes"). A new
  question to the registry or config, a new config setting a command reads
  among them, is a constructor of `RegistryRequest`, and a new way to end
  the command or to run something registered inside it one of
  `ControlRequest` (each module's "Where an addition goes"). A new
  sub-port is a constructor and a lift, or, for one the loop answers in
  place, a constructor and an `ask`. A new question about text or layout
  stays inside its own sub-port and changes nothing here.
- **The registry's questions and the loop's control are sub-ports of their
  own.** Decided 2026-11-18, by roadmap `structural-splits` phase 4. They
  had been `StateRequest` variants that `EditorState.handle` answered with
  a stand-in, since only the loop can answer them; twenty such variants had
  grown there, so a sub-port whose rule is that it reaches nothing outside
  the state grew a stub with each new config setting.
  - **Two sub-ports, not one.** A question to the registry is answered by a
    pure function of what the loop was told and changes neither the state
    nor the program, so it is one arm of the dispatcher. A control request
    changes the command's program: `giveUp` and `breakOff` end it, and
    `runCommand`, `askSource`, `askAtPoint` and `matchCandidates` put a
    registered program before the rest, so each is an arm of its own, in
    one exhaustive match. `giveUp` and `breakOff` ask the registry nothing,
    so a registry sub-port holding them would be misnamed. `askSource`,
    `askAtPoint` and `matchCandidates` are control requests because they
    are answered as `runCommand` is: a program runs inside the asking
    command, guarded, and can refuse it.
  - **No single read of config's readings**, as `StateRequest.read` is of
    the state. The language table cannot be in a reply: a `Language` holds
    a `Mode.SyntaxTree`, defined in `lean/Editor/Mode.lean`, which imports
    `Editor.Command`, so a reply type over it would make the port depend on
    itself. `ex`, `hasJob`, `categorySources` and `atPointSources` are
    lookups over what the registry holds as functions. A read would have
    replaced at most eight of the fourteen questions, and the sub-port would
    have had two shapes of question; AGENTS.md asks for a variant per
    question, and no command changes config's readings, so the state's
    reason for one read does not hold.
  - **Where no loop runs a command**, a runner answers both as with nothing
    registered (`RegistryRequest.bare`, `ControlRequest.bare`), the values
    the stand-ins had, `hasJob` answering yes for any name as `startJob`
    takes any. Behaviour seen from a command did not change.
  - `setMajorMode`, `setBufferMajorMode`, `startJob` and `loadTheme` stayed
    state requests: each is a state operation the loop gates on a
    registered name.

| Piece | Where |
|---|---|
| The composite port, `EditorM`, the six embeddings and lifts (the syntax tree's handing its refusal back as a value), and the mapping of the display's refusals | `lean/Editor/Command.lean` |
| The fuzzy port: its one request, which refuses nothing; `FuzzyHandler` | `lean/Editor/Fuzzy.lean` |
| Its pure model, with no state: a subsequence test, and the candidates that are the pattern first | `lean/Editor/Fuzzy/Model.lean` |
| Its contract, imported from the port alone, run against the model by `lake test` and against the real binding by `contract-test` | `lean/Editor/Fuzzy/Contract.lean` |
| Its real binding: one call into the library | `lean/Editor/Fuzzy/Real.lean` |
| The syntax tree port, a sub-port of the editor's: the grammars, attaching a text to a grammar, a query compiled, its capture names and its captures in a range, a grammar's shipped query, and a text highlighted with a query in faces, each refusal a value; `SyntaxTreeHandler`; `SyntaxTree.none`. Named `SyntaxTree`, since `Syntax` is `Lean.Syntax` wherever `Lean` is open and `Grammar` an input scheme's | `lean/Editor/SyntaxTree.lean` |
| The capture-to-face rule and what setting a major mode with a syntax tree asks of the port | `lean/Editor/Highlight.lean` |
| The language table, the rule that chooses a path's language, and the `code` mode, whose tree is its buffer's language's | `lean/Editor/Language.lean` |
| Its pure model: one grammar, a parser of a subset of JSON that builds the tree `tree-sitter-json` builds, a subset of the query language, and the Rust core's rule for a range; it parses at once, so it answers `notParsed` only when a test says its trees are not delivered (`delivered`) | `lean/Editor/SyntaxTree/Model.lean`, `Model/Json.lean`, `Model/Query.lean` |
| Its contract, imported from the port alone, run against the model by `lake test` and against the real binding by `contract-test`, whose runner waits for a snapshot's tree to be delivered before each question of captures | `lean/Editor/SyntaxTree/Contract.lean` |
| Its real binding: one call into the library a request, over the read half of the text binding's table of snapshots and a table of its own of the queries it compiled; a face crosses as its name, none as the empty string | `lean/Editor/SyntaxTree/Real.lean` |
| The clipboard port: its two requests, each refused as a value; `ClipboardHandler`; `Clipboard.unavailable` | `lean/Editor/Clipboard.lean` |
| Its pure model: the text held, and a clipboard a test takes away | `lean/Editor/Clipboard/Model.lean` |
| Its contract, imported from the port alone, run against the model by `lake test` and against the in-process clipboard by `contract-test` | `lean/Editor/Clipboard/Contract.lean` |
| The clipboard where there is no window (the headless host): a cell of the process that answers with the model's rule | `lean/Editor/Clipboard/InProcess.lean` |
| The state requests and their pure handler: one read of the whole state, and a request a write (a buffer, its history, values and modes; a window; the echo; a job to start), each refused with a value | `lean/Editor/State/Request.lean`, over the operations of `lean/Editor/State.lean` |
| The questions to the registry and config: an ex binding, the themes, config's settings, the language table, the jobs and the completion sources registered; what a runner answers where no loop runs the command | `lean/Editor/Command/Registry.lean` |
| The loop's control of a running command: giving up, breaking off, and running a command, a completion source, an at-point source or a category's style inside it; what a runner answers where no loop runs the command | `lean/Editor/Command/Control.lean` |
| A dispatched command: its state, registry and control requests answered from the loop's state and what it is told of the registry (`Loop.Registered.answer`), every other request guarded, so that it stops at its next one once the flag is up, a major mode's on-enter actions run inside it; `Guarded`, how it ended; and `Loop.Registered`, what the loop is told of the registry. The guard has this one definition | `lean/Editor/Command/Dispatch.lean` |
| The composite's model runner, over the five models side by side, and the fuzzy model, which has no state | `lean/Editor/Command/Model.lean` |
| The composite's real runner, over the text binding, a display handler, a watch handler, a clipboard handler, a syntax tree handler and the fuzzy port's real binding | `lean/Editor/Command/Real.lean` |
| `DisplayHandler`, and running a display program against one | `lean/Editor/Display.lean` |
| The watch port: the interrupt flag, lowering it, and the clock; `WatchHandler`; `Watch.idle`; the interrupt key, `C-g` | `lean/Editor/Watch.lean` |
| Its pure model: the interrupt keys that arrived, one that arrives at a command's n-th request, and a clock with a pace | `lean/Editor/Watch/Model.lean` |
| Its contract, imported from the port alone, run against the model by `lake test` and against the real binding by `contract-test` | `lean/Editor/Watch/Contract.lean` |
| Its real binding, over the library's interrupt flag and the job port's clock | `lean/Editor/Watch/Real.lean` |
| What the model runner does with each sub-port, pinned | `ModelTest.commandPortChecks` |

### The editor API

Built by the command loop's phase 8 (`lean/Editor/Api.lean`, whose module
docs have each operation's rules). It is what a command is written with
beyond the text port's own operations: programs over the composite port,
made of state requests, questions to the registry, control requests and
text requests. Config sees it through
`Editor.lean`.

| A command can | With | Reaches the library |
|---|---|---|
| Read the editor state: its buffers, windows, focus, a buffer's values and modes | `editorState`, then pure functions over it (`buffer?`, `target?`, `findBuffer`, `value?`) | No |
| Make, find and remove a buffer | `createBuffer`, `addBuffer`, `findBuffer`, `BufferId.remove` | To make the text and read its revision |
| Read a buffer | `BufferId.text`, then the text port's reads (`read`, `rowContent`, `slice`, …) | Yes: the text port's own requests |
| Insert and delete at positions | `BufferId.insertAt`, `BufferId.deleteRange`, over `TextId.replaceRange` | Yes: `apply`, with the user's origin |
| Insert at a view's selections, delete what they cover, read and place them | `ViewId.insertAtSelections`, `deleteSelections`, `selection`, `select`, and the same on a `Target` | Yes: `apply` carrying the selection before and the cursors after, and the marker requests |
| Close the undo group, undo and redo, each move handing back the selection to place | `BufferId.closeGroup`, `undo`, `redo`, over the buffer's undo tree | Yes: `applyInverse` and `dropInverses`, the undo tree's own; no new library call |
| Split, close and focus a window, and show another buffer in one | `ViewId.split`, `close`, `focus`, `show` | To mark the new window's markers |
| Set and read a buffer-local value; set the major mode, add and remove a minor mode | `BufferId.setValue`, `value?`, `ViewId.setMajorMode`, `BufferId.addMinorMode`, `removeMinorMode` | No |
| Keep a view's wanted column, the column its vertical motions aim for, with the offset the cursor was left at; read it from the view's window in the state, as it is when the command asks | `ViewId.setWanted`; `Window.wanted`, of `EditorState.window?` on `editorState` | No |
| Say something in the echo area | `message` | No |
| Start a job, with arguments | `startJob`, for a job registered with `jobWith` or `job` | No: the host starts it once the command has ended |
| Break a line with the buffer's line ending, and ask whether a buffer is modified | `ViewId.insertLineBreak`, `Target.insertLineBreak`; `BufferId.isModified` | Yes: `apply`, and the text's revision |
| Open a file into a buffer and save a buffer to its file | `Files.open`, `Files.save` (`packages/files/Files.lean`), each of which starts a compiled job | For the snapshot a save writes; the file is the job's to load or save |
| Ask for a string, without waiting for it, and accept or cancel the open prompt | `prompt label continuation initial`, which names the command that receives the answer as an invocation; `acceptPrompt`, `cancelPrompt` | To make the minibuffer's text and its markers, and to read the answer; a cancel reaches nothing |
| Ask with candidates the answer may be chosen from, replace an open prompt's, and move a choice through the ones it has listed | `prompt … (sources := …)`, where each source (`lean/Editor/Completion.lean`) is given as a value or named, and is a program over the editor's port that `prompt` asks once, a named one run by the loop; `setCandidates`; `chooseCandidate step`; config registers a source with `defineSource`. Accepting gives the continuation the chosen candidate, and the typed text when nothing is chosen ([concurrency.md](concurrency.md), "Prompts") | Whatever the sources ask; `setCandidates` and `chooseCandidate` reach nothing. The listing is the loop's, made before each scene |
| Which candidates a pattern matches, best first | `Fuzzy.rank pattern candidates`, the fuzzy port's own, lifted | Yes: one call, which keeps nothing in the library |
| Which ex names are bound | `exNames`, answered by the loop from the registry | No |
| Ask which command an ex name is bound to, and what the name takes | `exBinding name`, answered by the loop from the registry as it is at that step | No |
| Have another command run after it, as a step of its own | `invoke invocation` | No: the host runs it once the command has ended |
| Have the command registered under a name run inside it, as part of it, and learn whether there was one | `runCommand name call`, answered by the loop from the lookup a key's invocation goes through ([concurrency.md](concurrency.md), "Prompts") | Whatever the command run makes |
| End itself with a reason, rolled back, with the reason in the echo area | `giveUp reason` ([concurrency.md](concurrency.md), "Foreground: commands") | No |
| End itself with a reason and keep what it did, with the reason in the echo area and the input scheme back at rest | `breakOff reason` ([concurrency.md](concurrency.md), "Foreground: commands") | No |
| Keep a register, a text and whether it is line-wise, under a name, and read one | `setRegister name register`; `EditorState.register?` on `editorState` | No |
| Replace one extent in an edit that carries the two selections it is handed, the one from before the command and the one it leaves | `Target.replaceCarrying`, over `TextId.replaceCarrying` | Yes: `apply`, with the user's origin, and the marker |
| Read and write the system clipboard, each refused as a value | `Clipboard.read`, `Clipboard.write`, the clipboard port's own, lifted | No: the clipboard handler the host hands in |
| Ask the editor to quit; refused, as a value, while a buffer that holds a file has unsaved changes | `quit` | For the revision of each buffer that holds a file |
| Ask for the config to be reloaded | `reloadConfig` | No: the host asks its config session once the command has ended |
| Read and place its window's scroll anchor | `Target.anchor`, `Target.scrollTo` | Yes: the marker requests. Placing a marker is no edit |
| Ask the display about its view: which rows it shows, and where a position goes by visual rows | `Target.onArea run`, which hands `run` a snapshot of the buffer's text, taken there and released when `run` has ended, and the view's rectangle; then the display port's two queries, and the scroll policy over them (`lean/Editor/Scroll.lean`) | Yes: a snapshot and its release, and the display's queries |
| Set the scroll margin, the rows every view keeps round its cursor's row, and read it | `setScrollMargin rows`; `EditorState.scrollMargin` on `editorState` | No |

- **Edits go through `apply`**, as one transaction made by the user
  (`Origin.user`): one revision, one entry of the edit log, and one step
  for the buffer's history to be told of.
- **A refusal of the state is a value** (above); what the text store
  refuses is thrown, as everywhere in `EditorM`.
- **Giving up is the loop's.** A request that closes a window or removes a
  buffer changes the state alone. The loop gives up the window's markers
  and releases the buffer's text once the command has run to its end
  (`lean/Editor/Loop.lean`, "What a finished command gave up"), so a
  command that fails afterwards is rolled back whole.
- **The contract check.** Every operation that makes a request of the
  library has a case in `lean/Editor/Api/Cases.lean`: a command, played as
  the loop plays one, on the editor's models by `lake test` and on the real
  text binding by `contract-test`. An operation over Lean state alone has
  its one implementation, the state requests' handler, and is pinned once,
  on the models (`ModelTest.stateRequestChecks`,
  `ModelTest.apiStateChecks`).
- **Proved on the text model** (`lean/Editor/Api/Theorems.lean`):
  inserting a string at a character boundary and deleting the range it
  occupies leaves the text's contents as they were
  (`replaceRange_insert_delete`), from `TextModel.splice_insert_delete` and
  `TextModel.applyChanges_replacing` (`lean/Editor/Text/Model.lean`). The
  theorems are in a module of their own so that the API imports no model.
- **Files are commands over the API, not requests of the port**
  (`packages/files/Files.lean`, built by the command loop's phase 9). A
  command cannot wait, so opening and saving are each a command that
  starts a job and the command the job finishes with
  ([concurrency.md](concurrency.md), "Getting results back"). What they
  needed of the state is three requests: one that attaches a file to a
  buffer, and two that begin and end a save in flight. The jobs are
  compiled, registered beside the commands
  (`packages/files/Files/Compiled.lean`), which is the one module of the two
  that names the registry: config sees the commands through `Editor.lean`
  and not the registrations.
- **A prompt is a request and a named command, not a wait** (built by the
  command loop's phase 10; [concurrency.md](concurrency.md), "Prompts").
  A command cannot wait for an answer, and a request of the editor's port
  cannot carry the program that would receive it ("A request that carries
  a program over its own port", above). So `prompt` names the command
  that receives the answer, as an invocation, and returns at once; the
  open prompt is editor state; and accepting is one state request that
  closes the prompt and records the invocation with the answer as its
  first argument, which the loop's host runs as a step of its own. The
  commands a key runs for it, `minibuffer-accept` and `minibuffer-cancel`,
  and `minibuffer-next` and `minibuffer-previous`, which move a choice
  through a prompt's candidates (the command loop's phase 14), on `C-n`
  and `C-p` under the Vim scheme, `minibuffer-insert`, which puts the
  chosen candidate, or the first listed, in the input, on `TAB`
  (completion's phase 6),
  `minibuffer-delete-backward`, which deletes the character before the
  minibuffer's bar and cancels the prompt when the minibuffer is empty,
  and the minibuffer's mode are compiled (`packages/minibuffer/Minibuffer.lean`),
  registered by `packages/minibuffer/Minibuffer/Compiled.lean`, the one module of
  the two that names the registry: the default package `minibuffer`
  since the features-as-packages roadmap's phase 4, with its names in the
  interface package `minibuffer-api`.
- **Evil is commands over the API** (`packages/evil/Evil.lean`, built by the
  command loop's phase 11; [keymaps-and-modes.md](keymaps-and-modes.md),
  "The Vim scheme"): the move command, the commands that enter a Vim state
  and begin an insert, and the one typed text runs. Each is given its
  call, which carries what the input scheme reports of its view
  (`Call.report`), since a command cannot ask the scheme. They add no
  request to a port, so there is no new model and no new contract. A
  motion is a vocabulary entry (`lean/Editor/Vocabulary.lean`), a program
  over the text port alone. Config sees the commands, the motions and
  their table through the set's config base, whose module
  `Evil.EditorPackage`, the entry module of the default package `evil`,
  brings `packages/evil/Evil.lean`
  and `packages/evil/Evil/Motions.lean` (they were imports of `Editor.lean`
  while evil was in the core): the move command is a function of
  the table it looks a name up in, so a command of config's hands it the
  vocabulary that ships (`Evil.motions`), or that vocabulary with motions
  of its own added. The registrations (`packages/evil/Evil/Compiled.lean`)
  name the registry, and are what the entry module lists as the package.
  Pinned by `EvilTest.Linked.evilChecks`, on a config the real elaborator
  loads.
- **Evil's editing commands** (the command loop's phase 13): the operators
  and the operate command, `x`, the registers and the two puts, the two
  commands that open a line, undo and redo, and dot repeat, each in a
  module of its own beside `packages/evil/Evil.lean`. They needed four state
  requests (`giveUp`, `breakOff`, `setRegister`, `runCommand`), one operation of the API
  (`replaceCarrying`, with a case in `lean/Editor/Api/Cases.lean`), and
  one new sub-port, the clipboard's, with its model and its contract
  ("The editor's port is a composite"). An operator is a vocabulary entry
  whose action is a command's body, so the vocabulary imports the port.
  `Editor.lean` imports them, so config calls the operate command with
  the tables that ship or with tables of its own, and the repeat and undo
  commands.
- **The ex line is commands over the API** (`packages/ex/Ex.lean`, built
  by the command loop's phase 12;
  [keymaps-and-modes.md](keymaps-and-modes.md), "The ex command line"):
  `ex`, which asks for a line and runs it, and `quit`, `save-and-quit` and
  `reload-config`. They needed four state requests. Two name something
  the host holds: which command an ex name is bound to (`exBinding`),
  which the dispatcher answers from the registry, as it answers a major
  mode's name and a job's (a question to the registry,
  `RegistryRequest.ex`, since roadmap `structural-splits` phase 4); and a reload (`reloadConfig`), a one-shot
  output of the step. One has a command run after another (`invoke`), in
  the field a prompt's answer is recorded in. One asks the editor to quit
  (`quit`), which is a flag of the state the step turns into "stop"
  ([concurrency.md](concurrency.md), "Quit"). None adds a request to
  another port, so there is no new model and no new contract; `quit` asks
  the text port for revisions, and has a case in
  `lean/Editor/Api/Cases.lean`. The registrations and the ex names the
  `ex` package binds (`packages/ex/Ex/Compiled.lean`) name the registry and
  are not imported by `Editor.lean`.
- **A command asks layout a question through its view's area** (built by
  the command loop's phase 15;
  [text-and-display.md](text-and-display.md), "Views as built";
  [keymaps-and-modes.md](keymaps-and-modes.md), "Scrolling as built").
  - `Target.onArea` reads the view's rectangle from the state
    (`EditorState.rect?`, the definition the scene's views are laid out
    by), takes a snapshot of the buffer's text, runs the command's
    program with both, and releases the snapshot, also when the program
    was refused. A command that is interrupted, gives up or breaks off
    inside it leaves the snapshot: the loop ends a command's program at
    that request, and a snapshot a command took is not undone.
  - The take, the release and the rethrow are one helper,
    `TextId.withSnapshot` in `lean/Editor/Command.lean`, beside the lifts:
    the lowest module that has a command's type, which the API and the
    evil vocabulary both import. `Target.onArea` is the rectangle's lookup
    and that helper, and a motion that asks the display calls it with the
    text it is handed (`j` and `k`, `packages/evil/Evil/Motions.lean`). So
    the release rule, and what an interrupted command leaves, is in one
    place.
  - The policy that says where a scroll anchor goes is
    `lean/Editor/Scroll.lean`: programs over the display port alone,
    which the API imports. It holds no state, and nothing of an answer of
    layout is kept between two questions.
  - `Target.anchor`, `Target.scrollTo` and `Target.onArea` each have a
    case in `lean/Editor/Api/Cases.lean`, and so has the loop's follow,
    which asks the display about the scene's own snapshots. No request
    was added to a port: the display's two queries were there, and the
    margin is one state request (`setScrollMargin`).
  - Evil's scroll commands are in `packages/evil/Evil/Scroll.lean`, which
    the set's config base brings, so a command of config's calls `Evil.scroll`
    and `Evil.scrollLineTo`, or the API's operations.

| Piece | Where |
|---|---|
| The operations | `lean/Editor/Api.lean` |
| Their cases, played on the models and on the real binding | `lean/Editor/Api/Cases.lean` |
| What is proved of them on the text model | `lean/Editor/Api/Theorems.lean` |
| The file commands, their jobs' work, their orders and what they say in the echo area | `packages/files/Files.lean` |
| The package `files`: the file commands and their jobs | `packages/files/Files/Compiled.lean` |
| The commands that accept and cancel a prompt, and the minibuffer's mode | `packages/minibuffer/Minibuffer.lean` |
| The package `minibuffer`: the minibuffer's commands and its mode | `packages/minibuffer/Minibuffer/Compiled.lean` |
| The vocabulary: the motion record and the operator record | `lean/Editor/Vocabulary.lean` |
| Evil: where a cursor rests, and the commands the Vim scheme's invocations run that are not below | `packages/evil/Evil.lean` |
| Evil's motions, as vocabulary entries, and their table | `packages/evil/Evil/Motions.lean` |
| Evil's operators, as vocabulary entries, their table, what an operator takes, the operate command and `x` | `packages/evil/Evil/Operators.lean` |
| Evil's registers, storing and fetching, and the two puts | `packages/evil/Evil/Registers.lean` |
| Evil's undo and redo, which place the selection a step hands back | `packages/evil/Evil/Undo.lean` |
| Evil's dot repeat: the repeat command | `packages/evil/Evil/Repeat.lean` |
| The scroll policy: how a view follows its cursor, the margin, and the anchors a scroll places | `lean/Editor/Scroll.lean` |
| Evil's scroll commands: by half a view, by a view, and to the cursor's row | `packages/evil/Evil/Scroll.lean` |
| What is proved of evil on the text model, and of the undo tree | `packages/evil/Evil/Theorems.lean`, `lean/Editor/UndoTree/Theorems.lean` |
| The package `evil`: evil's commands | `packages/evil/Evil/Compiled.lean` |
| An ex line as data: its name and argument, and an ex binding | `lean/Editor/Ex/Line.lean` |
| The ex command, and the commands `quit`, `save-and-quit` and `reload-config`, with what they say in the echo area | `packages/ex/Ex.lean` |
| The package `ex`: the ex line's commands and the files', its own and the buffers' ex names | `packages/ex/Ex/Compiled.lean` |
| The command `load-theme`, which switches the theme in force with no reload, with what it says in the echo area | `packages/themes/Themes.lean` |
| The package `themes`: the command that loads a theme and the theme `default` | `packages/themes/Themes/Compiled.lean` |
| The package `shipped-themes`: the palettes that ship, a default package outside the core | `packages/shipped-themes/ShippedThemes.lean` |
| The theme picture check, a test double: a theme drawn, held to its palette's colours and to a reference image | `lean/Editor/Theme/Picture.lean` |
| The command prompt, `execute-command`, which lists every registered command's name and runs the one accepted, with its completion source `commands` and what it says in the echo area | `lean/Editor/ExecuteCommand.lean` |
| The package `execute-command`: the command prompt and its source | `lean/Editor/ExecuteCommand/Compiled.lean` |
| The binding search, `search-bindings`, which lists every key binding the input scheme reaches in the asking view and runs the one accepted as its key would, with its completion source `bindings` and what it says in the echo area | `lean/Editor/BindingSearch.lean` |
| The package `binding-search`: the binding search and its source | `lean/Editor/BindingSearch/Compiled.lean` |
| The loop on the models with jobs, for tests of a command that starts a job: a job reads the snapshots commands took, and its command is handed what the job loaded | `lean/Editor/Loop/Driver.lean` |

## Where state lives

| State | Held by | Across a reload | Across a restart |
|---|---|---|---|
| Buffers, windows, keymaps, registers, the agent table | Compiled Lean, on the editor thread. Buffers, windows, the frame's window list and layout, the echo area and the preedit are the editor state (`lean/Editor/State.lean`), which the command loop (`lean/Editor/Loop.lean`) holds and is the one writer of: a command changes it by requests the loop answers. Buffers are kept in slots, so a buffer's id is never used again, and neither is a view's | Untouched | Restored after a run that did not end cleanly (`lean/Editor/Restore/Run.lean`): each buffer's file, line ending, modes and unsaved text; and every window of every tab, tiled, docked and floating, with the layouts, zooms, names, the focused and last-focused windows, the tab in view, each window's selection, scroll and jump list (`lean/Editor/Restore/Frame.lean`). The start window keeps its id; every other gets a new one. A window whose buffer is not kept shows `scratch`, said. The wanted column, secondary cursors, marks, registers and buffer-local values are not restored. The rest is lost unless its owner persists it |
| The session index, format 2: each buffer's file, line ending, modes and live journal, the place and jump list of every window on it, and the focused view; the frame's tabs and windows (`frame`); the workspace table with the cells whose store has a codec (`workspaces`); the declared stores' cells kept across a restart (`stores`); and the reported jobs running (`jobs`), with how many others run that their owner does not restart (`otherJobs`, recorded by the next write another change starts) | Compiled Lean keeps what it last wrote and what it mirrors (`EditorState.restore`, `Restore.Kept`); the job `restore-write` writes it, debounced, to `<state>/session/session-<run>.json`, one file a run, written only by that run (`lean/Editor/Restore/Document.lean`) | Untouched | Kept: read by the next start; a clean end writes it saying `ended`, and then nothing is restored |
| Store values kept across a restart and not yet met: config's declared cells and the table cells whose codec config registers, which the restore reads before config's `setup` | The config state's `parked` (`Config.State.parked`, `lean/Editor/Config/Reload.lean`) for declared cells, and `Restore.Kept.parked` for table cells | Config's first install that declares a parked store with a codec meets it (kept, migrated or reset, said); the others are dropped, said. A rejected reload keeps them | Carried into every index written until claimed or dropped, so a config whose `setup` throws loses nothing |
| A restart in flight: its plan, whether its save has started (`Restore.Kept.handing`); and the hand-over record, `<state>/session/handover`: the index the next run restores, the shipped executable, the candidates in order, the editor's arguments and the launcher's `failed` lines | The plan, compiled Lean in the editor state; the record, a text file the job `restart-save` writes once, which the launcher and its watcher read and rewrite (`crates/editor-launch/src/handover.rs`) and the next run removes at the hand-shake | Untouched | The record is what crosses it: the next run removes it once it has restored the index it names and written its own; when every candidate failed the launcher renames it `handover.failed`, which the next start says and removes |
| Unsaved text: the journal of each buffer with unsaved changes | A base, the text whole, and a log of JSON lines, one record of edits per event, under `<state>/session/journals/` (`lean/Editor/Restore/Journal.lean`), written by the file service from the orders the loop hands it after each publish | Untouched | Kept: replayed at start-up after a run that did not end cleanly; removed when its buffer is saved or closed, and at a clean end |
| A buffer's local values: plain trees by name (`Value`), as a store's cell holds | Compiled Lean, a field of the buffer in the editor state, set and read by a command (`BufferId.setValue`, `BufferId.value?`) | Untouched: a tree names no type of config's | Lost |
| A job running: one a person waits on registers itself reported (`workJob … (reported := true)`: the shell's run, the compile run, project search, version control's apply, hunk apply and commit); one its owner starts again after a restart registers itself restarted (`workJob … (restarted := true)`: the files' `check-files` and `follow-file`, the workspace's `find-workspace`, `find-mode-markers` and `compile-list`, the gutter's three and the restore's six, a restart's probe and save among them) | The host's job table, off the editor thread; the reported ones are handed to the loop each step (`Loop.Keys.running`), and how many others run that are not restarted (`Loop.Keys.otherJobs`) | Config's jobs are cancelled by an install; a package's run on | Not restarted: the next start's restore says each reported job that was running was stopped by the restart, and how many others were, a package's or config's, in `*restore*` and the summary; a restarted job is not said, as its owner starts it again |
| A buffer's changed-on-disk mark: what the last check of its file found that is not the file it holds, and whether the user was told (`Buffer.File.changed`) | Compiled Lean, a field of the buffer's file in the editor state, set by the command a check finishes with (`BufferId.markChanged`, `BufferId.tellChanged`) and cleared by a load, a reload or a save | Untouched | Lost: a check after a restart finds the file as it is |
| What the loop saw at its last publish (`Loop.seen`): the focus, the buffers shown, modified and open, which decide the files due a check | Compiled Lean, a field of the loop | Untouched | Lost |
| The input scheme's state: the pending keys and what the scheme keeps for each view (the Vim scheme's states, its last change, and the text typed in the insert session that change began) | Compiled Lean, in the command loop, which runs one scheme for its life | Untouched | Lost |
| The registers: a text and whether it is line-wise, by name. Evil keeps the unnamed one, which every yank and deletion sets | Compiled Lean, a field of the editor state (`EditorState.Remembered.registers`, `lean/Editor/State.lean`), set by a command (`setRegister`), so it is rolled back with a command that does not run to its end | Untouched | Lost |
| The system clipboard | Outside the editor: reached through the clipboard port. A host with no window keeps one of its own in the process (`lean/Editor/Clipboard/InProcess.lean`) | Untouched | The window system's is the system's; the in-process one is lost |
| Packages' commands, jobs, key bindings, modes, ex bindings and themes | Compiled Lean, in the registry, each for the owner named after its package ("Packages", under "Config and reload"). The executable ships the command `load-theme` and the theme `default` (`packages/themes/Themes/Compiled.lean`), the command prompt `execute-command` with its source `commands` (`lean/Editor/ExecuteCommand/Compiled.lean`), the binding search `search-bindings` with its source `bindings` (`lean/Editor/BindingSearch/Compiled.lean`), the ex line's four commands, `ex`, `quit`, `save-and-quit` and `reload-config`, and the ex names `w`, `w!`, `e`, `e!`, `q`, `wq` and `reload` (`packages/ex/Ex/Compiled.lean`), the file commands, `open-file`, `save-buffer`, `edit-file` and `reload-buffer`, and their jobs, `load-file`, `save-file` and `reload-file`, with the file prompt's source `files`, its job `files` and the style `path` as the category `file`'s compiled default (`packages/files/Files/Compiled.lean`, `lean/Editor/Completion/Paths.lean`), the minibuffer's commands, `minibuffer-accept`, `minibuffer-cancel`, `minibuffer-next`, `minibuffer-previous`, `minibuffer-insert`, `minibuffer-delete-backward` and `minibuffer-delete-to-start`, and its mode, `minibuffer` (`packages/minibuffer/Minibuffer/Compiled.lean`), and evil's thirty-seven commands, `move`, `normal`, `visual`, `visual-line`, `insert`, `append`, `insert-line-start`, `append-line-end`, `self-insert`, `operate`, `select-object`, `delete-char`, `put-after`, `put-before`, `open-below`, `open-above`, `undo`, `redo` and `repeat`, over its compiled tables of motions, operators, text objects and changes, and the seven that scroll a view, `scroll-down`, `scroll-up`, `scroll-page-down`, `scroll-page-up`, `scroll-line-to-top`, `scroll-line-to-center` and `scroll-line-to-bottom`, the seven editing keys of insert state, `insert-delete-backward`, `insert-newline`, `insert-tab`, `insert-left`, `insert-right`, `insert-up` and `insert-down`, and the four of the Edit menu, `clipboard-cut`, `clipboard-copy`, `clipboard-paste` and `select-all` (`packages/evil/Evil/Clipboard.lean`) (`packages/evil/Evil/Compiled.lean`), and `workspace-current` with the job `find-workspace`, and `find-file-in-workspace` with its source `workspace-files`, of the category `workspace-file`, and its job `workspace-files` (`packages/workspace/Workspace/Compiled.lean`), and the `project-search` package's `project-search`, `project-search-found` (which its job posts each delivery as), `project-search-symbol` and `project-search-visit`, its results buffer's mode `project-search`, and its jobs `project-search` and `project-search-load` (`packages/project-search/ProjectSearch/Compiled.lean`), and the `working-set` package's six commands, a set's buffer's mode `working-set` and its four jobs (`packages/working-set/WorkingSet/Compiled.lean`) | Untouched: a reload replaces config's, and cancels config's jobs only, so a compiled job that is running goes on | Registered again when the host starts |
| An open prompt: its label, the minibuffer's view, the asking view and the continuation, its candidates with what it has listed of them and the choice, all plain data, with the minibuffer's buffer and window | Compiled Lean, a field of the editor state (`EditorState.prompt`, `lean/Editor/State.lean`) and a buffer and a window of it, from the command that asks until the one that accepts or cancels | Untouched: the prompt stays open, and its continuation is a name, looked up in the registry as it is when the answer arrives | Lost |
| A save in flight: the snapshot a save writes and the state its text was in | Compiled Lean, with the buffer's file in the editor state, from the save command until the save's result is delivered | Untouched | Lost with the buffer |
| Asked to quit: whether a command asked the editor to quit | Compiled Lean, a field of the editor state (`EditorState.quitting`), from the command that asks until the step that says stop, or until the scene that withdraws it because a buffer has unsaved changes | Untouched: a quit that is waiting for a save still waits | Not kept: the process has ended |
| A view's wanted column: the column its vertical motions aim for, with the offset the cursor was left at | Compiled Lean, a field of the view's window in the editor state (`Window.wanted`), set by a command (`ViewId.setWanted`) | Untouched | Lost |
| A view's scroll position | An anchor marker of the buffer's text, in the text store, named by the view's window (`Window.scroll`). The loop places it before each scene so that the view shows its cursor, and a scroll command places it (`Target.scrollTo`). The loop keeps and restores it round a command, so a command that does not run to its end leaves it | Untouched | Lost |
| The scroll margin: how many rows every view keeps between its cursor's row and the first and the last row it shows | Compiled Lean, a field of the editor state (`EditorState.scrollMargin`, 0 in a new state), set by a command (`setScrollMargin`), so it is rolled back with a command that does not run to its end. Config cannot set it when it loads: `setup` runs no command, and the one setting there is, auto-reload, is not it | Untouched | Lost |
| Auto-reload: config's setting (`autoReload` in `setup`, `Config.Registry.autoReload`, false when config says nothing, a second call refused), a command's choice (`EditorState.autoReload`, `none` until `auto-reload-mode` sets it), and what the loop follows (`EditorState.following`) | Config's setting in the registry, installed with the config; the choice and the following in the editor state | Config's setting is replaced with config's; the command's choice is untouched and decides over it | Lost |
| The workspace table: each workspace found or registered this session, with its location (its one root), its branch and its project, and its store of values by name, keyed by location ([projects.md](projects.md)) | Compiled Lean, a field of the editor state (`EditorState.workspaces`, `lean/Editor/Workspace.lean`), written by state requests (`recordWorkspace`, `registerWorkspace`, `setWorkspaceValue`). A buffer names its workspace by a buffer-local value, its location | Untouched: cells are `Value` trees | Restored with the session: every workspace, with the cells whose store has a codec (`Store.keptAcrossRestart`), met by the install rule; a cell whose codec config registers is parked until it installs; a store with no codec starts empty |
| The project table: each project of those workspaces, with its store of values by name, keyed by identity | Compiled Lean, in the same table (`setProjectValue`) | Untouched | Restored as the workspaces are |
| The directory cache: each directory a file was opened in, the location of its workspace or none, and the config generation it was found under | Compiled Lean, in the same table, recorded by the find job's command. The config generation is the registry's (`Registry.generation`), bumped by every install | Kept, but an answer only under its own generation: the next open after an install asks git again | Lost: a restored file buffer is attached to its workspace again by the finder |
| Config's workspace listers: the command that lists a workspace root's files, or every workspace of a project's (`workspaceLister`, `projectLister`, [projects.md](projects.md), "Listing a workspace's files") | Config's, in the registry (`Registry.workspaceListers`), installed with the config and told to the loop in its workspace settings | Replaced by the new config's: the next `find-file-in-workspace` lists with them; a rejected reload keeps the old ones | Re-registered by `setup` |
| Layout: where a text wraps, how tall a row is, which rows a view shows | The display, in the Rust library. Lean keeps no copy: it asks the display's two queries each time, and keeps nothing of an answer | Untouched | Not kept |
| A buffer's modes: its major mode and its minor modes, by name | Compiled Lean, a field of the buffer in the editor state | Untouched: a name whose mode a reload drops contributes nothing | Lost |
| A mode's own state | A compiled mode's, a typed field where the editor state's table puts it (the one mode that ships, the minibuffer's, keeps none); a config mode's, a store its `setup` declares, whose commands fill its roles and suffixes, with per-buffer state in the buffer's local values, or inside the store's value | As for compiled state, and as for a store | As for compiled state, and as for a store |
| Text, kept inverses, anchors | Rust, behind handles | Untouched | Files on disk; the kept inverses are lost |
| The undo tree of each text: its nodes, where the text is in it, and the state last saved | Compiled Lean, with the buffer it is the history of, on the editor thread | Untouched | Dropped (session-restore phase 2, decision 1: a tree's kept inverses grow without bound, and importing them needs work of the text port none of which exists): a buffer the restore makes or reopens is marked (`Buffer.historyRestored`), and `u` at its root says `nothing to undo: no history before the restore` |
| A file's stamp (when it was last modified and how long it is, as the last load or save answered it), its path and its line ending | Compiled Lean, fields of the buffer that shows the file, in the editor state (`Buffer.file`, `Buffer.lineEnding`, `lean/Editor/State.lean`): the path a buffer is found by, the stamp the next save expects, and the line break a command inserts. A command sets them by one request (`BufferId.attachFile`) | Untouched | Lost; the file is loaded again |
| The snapshots a job's loads made | The job runner, off the editor thread, until the job's command adopts one or the job is settled | A reload that installs cancels the old config's jobs, which releases them | Lost |
| Processes, terminals | Rust, behind handles | Untouched | Lost |
| `acp`'s agent table, one a project: each session's identity, workspace, attention and activity (`agents-table`, declared by `agents-api`) | The project's store ([projects.md](projects.md), "What lives where"), as `Value` trees, fed by `acp`'s commands through a pure reducer ([agent-hosting.md](agent-hosting.md), "The agent table and resume, as built") | Untouched | Kept by its codec, which `acp` registers: each record as `AgentRecord.afterRestart` keeps it, with no transcript; a session is resumed from the agent's own store on its first visit |
| `acp`'s agents lists and its stall watchdog's notes: the list buffers' numbers, and the ids of the agents whose watchdog is armed (`acp-agent-lists`, `acp-agent-watch`) | The unscoped store; a list's text is derived from the project's table and the conversations on each redraw | Untouched | Lost |
| `acp`'s conversations, its permission queue buffers and its audit log's outbox: each conversation with its items, a pending permission request among them; the queue buffers' numbers; the audit lines not yet written and the write in flight (`acp-conversations`, `acp-permission-queues`, `acp-permission-audit`) | The unscoped store ([projects.md](projects.md), "What lives where"), as `Value` trees; the queue buffer's text is derived from the conversations on each redraw ([agent-hosting.md](agent-hosting.md), "Permissions, as built") | Untouched: a request pending across a reload is still in the queue and can be answered, the session job, a package's, running on | Lost |
| The permission audit log: every permission request and its answer, one record a line | A file, `<state>/agents/permissions.log`, appended by the job `agent-audit`, one write at a time, through the job port's file requests ([agent-hosting.md](agent-hosting.md), "Permissions, as built") | Untouched | Kept, and never read by the editor |
| Closures registered by config | Compiled Lean, tagged with their owner | Replaced by the new config's | Re-registered by `setup` |
| A workspace's working sets: each range's stored form and where it is held, what is known of the file on disk, the last set used | Compiled Lean, the workspace's store `working-sets` (`packages/working-set/WorkingSet/Places.lean`), its ranges held by anchor markers of their files' buffers | Untouched | Kept: written by jobs to `<state>/workspaces/<key>/working-sets.json` under the state directory, read lazily the first time a working-set command needs them, each range found again in its file's text or shown drifted (`packages/working-set/WorkingSet/Disk.lean`) |
| A user's package-set editors: `<data>/editors/<core>/<n>/`, each an executable with its records and its modules, and `<data>/editors/staging-<k>/` while a build installs ([packages.md](packages.md), "User package sets") | Files under the data directory (`--data`, else `$XDG_DATA_HOME/leanmacs` or `~/.local/share/leanmacs`), written by the job `package-build` and pruned after each publish to two versions of the current core and the running editor's | Untouched; a reload whose set differs starts a build | Kept: the launcher starts the newest of the shipped default's core at a cold start |
| A cold start's record: `<data>/launch/cold-<pid>`, the hand-over record with no session | Written by the launcher before it starts a per-user editor, read and rewritten by its watcher, removed by the editor at its hand-shake | Untouched | Removed by the run it started; when every candidate failed, renamed `.failed` |
| Values of types that config defines | See below | Converted or dropped | As for a reload |

Compiled state needs no special mechanism. That is the main simplification
over the first design, where Rust had to store all Lean state as plain data.

**State of config-defined types** is the one case that needs care. After a
reload the type may have changed, so a value built by the old config cannot
be handed to the new one. Config keeps such state in a **store**: a named,
owned cell whose type has an encoding to a plain value tree and a version.
On reload the value is decoded by the new config; a version change runs a
`migrate` function or drops the value, as the owner chose.

As built (`lean/Editor/Store.lean`, `lean/Editor/Config/Stores.lean`), a
store is a whole-value cell, and it is editor state, not a request of the
editor's port:

- **What config writes** is a `Store α`: a name, a version, an initial value,
  `encode : α → Value`, `decode : Value → Option α` and `migrate`, from an
  older version's tree to this version's. `Value` is a plain tree: null,
  bool, nat, int, string, list, record. `setup` declares the store and
  registers commands over it, each a function `α → EditorM α`.
- **Where the value lives.** A cell is an owner, a name, a version and a
  `Value`, in a table in the editor's state on the editor thread. It holds
  no type of config's, so a reload leaves it where it is. To run a store
  command the editor hands the cell's tree to the registered step (decode,
  run, encode: all config's code) and writes the result back only if the
  command succeeded.
- **On install**, for each store the new config declares: no cell makes one
  from the initial value; a cell at the declared version is kept if the new
  config can decode it; a cell at another version becomes `migrate` of it. A
  cell the new config cannot decode, or does not migrate, is reset to the
  initial value, and the reload's report says so. A cell the new config no
  longer declares is removed. Declaring a store name twice, registering a
  command name or a job name twice, setting a face twice, defining or naming
  a theme twice, or registering a command over an undeclared store rejects
  the reload.
- **Why not a request of the editor's port.** The editor's port is now a
  composite of sub-ports ("The editor's port is a composite", above), and a
  `get` and a `set` would be a store sub-port of it. Stores still do not use
  it: state-passing commands need no change to `EditorM`. They limit a
  command to one store; a store sub-port can be added later without
  changing the cell, the encoding, the version or the install rule.
- **No model and no contract check.** The store never reaches the Rust
  library. Its one implementation is the pure core, which the model tests
  and the real editor both run.

**Persistence across a restart** is a store's opt-in (session-restore
phase 2, decisions 2 to 4). Every store already has a serialisation, its
encoding to a plain tree with a version and a migration (`Store.encode`,
`decode`, `migrate`); `Lean.ToJson` lives outside config's closure, so it is
not used. Whether a value means anything in the next process is the
store's to say, so a store is kept only when its owner's `setup` registers
a codec for it, `store.keptAcrossRestart (keep := …)`
(`lean/Editor/Store/Codec.lean`): `keep` is what of a value outlives the
process, so a store that holds a buffer number drops it there. The codec
covers both kinds of cell: a declared store's (`Store.declare`) and a
workspace, project or unscoped store's of the table. The session index
writes the codec's tree as lossless JSON (`lean/Editor/Restore/Value.lean`);
the restore meets it with the store's declaration by the install rule
(`StoreDeclaration.meet`): kept, migrated, or reset with a warning. A
package's codec is registered before the restore, so its cells are met
there; config's after, so its cells wait parked until config's first
install, and are carried into every index meanwhile. The shipped stores
that opt in are the shell's history and version control's reviews (their
review buffer's number dropped). A store with no codec is never written,
and starts empty, as before.

**As built, the state directory** (navigation-and-windows phase 5) is where
what is kept across a restart lives: `--state <dir>`, or `leanmacs` under
`$XDG_STATE_HOME`, or under `$HOME/.local/state`, and none when neither is
set (`Window.defaultState`). The host hands it to the loop's first state
(`EditorState.stateDirectory`, through `EditorState.hostedBy`, with the
working and home directories); the headless host's is none unless it is
given `--state <dir>`, so by default a headless run keeps nothing and every
fixture without `--state` is unchanged. Working sets are the first state
kept there, per workspace ([projects.md](projects.md), "What lives where");
session restore is the second (`<state>/session/`, `lean/Editor/Restore.lean`;
its index is of format 2 since phase 2, which added the frame, the
workspace table, the stores and the jobs);
the review record on disk is to reuse it. Its rules, which a later user
follows:

- **Only jobs touch it**, through the job port's file request: a load
  (`File.load`), a directory made with its parents (`File.makeDirectory`,
  added for it down the file port), and the file service's atomic
  temporary-and-rename save of a snapshot, so a reader never sees a torn
  file.
- **The journal's writes are the one exception** to "only jobs touch it"
  (session-restore phase 1, decision 5): they are fire-and-forget file
  requests, unobserved, which the loop hands the file service after each
  publish (`Loop.Stepped.journal`). Nothing awaits them; they run in order
  with the jobs' file requests on the service's one thread; a failure is
  kept by the service and said in the echo area once per path. A host's
  end waits for them with a flush, never a count. They stay unobserved, and
  not handles (`Job.Services.fileWorked`), for the editor thread's cost:
  3.3 to 3.9 µs a key against 34 to 66 µs (deterministic-test-concurrency
  phase 2; [concurrency.md](concurrency.md), "The session journal"; task
  `job-wait-table-copy-cost`).
- **It is read lazily**, the first time a command needs it, by a job whose
  command runs the asking command again: a start waits on no disk. **Session
  restore is the amendment**: its job reads `session/` at start-up, since it
  must run before config's `setup`. What the rule protects still holds: the
  read is a job's, the editor thread never waits on disk, and window events
  are handled meanwhile; only the driver's start-up requests wait for it.
- **A version rule**: a missing file is empty; one that does not parse, or
  whose version is newer than the editor's, is left as it is for the run,
  said once, and never written over. Never fail to start, never lose what
  is not understood. Session restore keeps it by writing **one index file
  a run**, `session-<run>.json`, and no other: it restores the index of the
  highest run, reading a newer format leniently, and removes only earlier
  indexes of a format it understands, once its own first index is
  written.
- **No state directory** keeps everything in memory, said once; and
  `:restart` is refused.
- **One file is outside the editor's hands: the hand-over record**
  (session-restore phase 3), `<state>/session/handover`, which a restart
  writes once by a job's snapshot save and which the app's launcher and its
  watcher, programs outside the editor, read and rewrite (a `failed` line
  each) and rename to `handover.failed` when every candidate failed. The
  next run removes the record at the hand-shake, and a start that finds
  `handover.failed` says it in `*restore*` and removes it. The launcher
  refuses a record of a later format and leaves it as it is.
- **Writes are keyed by the workspace's root**, so a newer write cancels an
  older one still in flight; two editors writing one workspace's file:
  the last writer wins.

## Events and reducers

Events arrive on the editor queue as plain data. The intended way to
consume a stream of them is a **reducer**: a pure function from state and
event to new state.

```lean
def AgentTable.step (s : AgentTable) : AgentEvent → AgentTable
  | .statusChanged id st => s.setStatus id st
  | .exited id code      => s.markExited id code
  | …
```

Because it is pure it can be tested and reasoned about with no library.
Side effects (notify the user, start a job) are returned as data alongside
the new state and performed by the runtime. This is the shape that survived
in `edmacs`: one table, one writer, one change event.

The editor loop keeps running during a reload, so events are not held back
and there is no gap to bridge.

## Subscriptions

Hooks in Emacs are lists of functions that accumulate. Here a subscription
is a record: the event kind, an optional subject filter (this buffer, this
agent), the handler, and the owner. On reload every subscription an owner
had is replaced. Handlers always receive their subject explicitly.

## Compiled and interpreted code

| | Interpreted | Compiled into the executable |
|---|---|---|
| Speed | A loop iteration costs about 0.1 µs; calls into compiled code and Rust run at native speed | Native |
| Live reload | Yes | No |
| Used for | User config; features under development | The editor core; the standard library |

A feature can be developed interpreted and compiled in once it settles. A
compiled feature registers as a package ("Packages", under "Config and
reload"), with the `setup` operations config uses. A
user who wants to change a compiled feature overrides its registration from
config (a key binding, a command name, a handler): config's entry of a
package's name is the one found. Replacing a function that
other compiled code calls directly is not possible without rebuilding.

## Memory and size

Memory is set by how much is imported at runtime, not by the architecture.
Importing only Lean's `Init` gave about 375 MB; an API that also imports
the standard hash map gave about 485 MB; importing all of the `Lean`
package gave about 1.2 GB. So the editor API's imports are kept deliberate,
and config that imports the `Lean` package pays for it.

The executable is large because Lean's elaborator is linked in: `editor` was
13 MB before it could elaborate config. `ffi-test` and `config-test` are the
same size for the same reason. As built, in MB (10⁶ bytes):

| Executable | macOS (arm64) | Linux (aarch64) |
|---|---|---|
| `editor` | 181.6 | 266.1 |
| `ffi-test` | 181.3 | 265.7 |
| `config-test` | 181.9 | 266.5 |
| `contract-test` | 4.3 | 14.7 |
| `model-test` | 3.7 | 6.8 |

The window library added 2.3 MB to `editor` on macOS.

`mise run config-bench` measures start-up time and resident memory for the
import sets `Editor`, `Editor` with `Std`, and `Editor` with `Lean`, in the
executable as built: on 2026-11-19, 0.20 s and 596 MB, 0.26 s and 724 MB,
and 0.54 s and 1,389 MB. Its two soaks measure memory across reloads of a
config that imports `Lean`: resident memory after 500 reloads was 1,440.0 MB
against 1,440.3 MB after 100 for a root alone, and 1,671.9 MB against
1,635.9 MB, +2.2%, for a root and an imported config file that changes each
round ("Config and reload" says why the second grows a little). So an
editor whose config imports `Lean` holds about 1.4 GB, and one whose config
does not holds about 0.6 GB: the base grows to hold `Lean` only when a
config file imports it.

### What config may import, measured

A config file may import a module of the editor's package set and a module
of `Init`, `Std` or `Lean`, and an app bundle carries the module files such
an import reads, since it can rely on no toolchain on the machine. Which
files those are, and what a base with `Lean` costs, was measured from
staged bundles (the stage script then, the `stage-bundle` binary now), on 2026-11-19, on an Apple M5
Max, macOS 27.2, Lean 4.35.0, with

```sh
mise run module-bench
```

(`tools/module-bench.sh`; [on-demand-checks.md](../dev-practices/on-demand-checks.md)).
MB are 10⁶ bytes of apparent size. "Whole directories" are the toolchain's
top-level `Init` and `Std` (and `Lean` for the second set) with their root
files, and the package's `Editor`; "closure" is the modules the import
reads, which `config-test bench-modules` lists.

| | `Editor` | `Editor` with `Lean` |
|---|---|---|
| Modules the import reads | 907: `Init` 653, `Std` 139, `Editor` 115 | 2,489: `Init` 653, `Std` 494, `Lean` 1,227, `Editor` 115 |
| File kinds the import reads | `.olean`, `.olean.server`, `.olean.private` | the same |
| Bytes, those kinds, whole directories | 872.5 MB | 1,866.0 MB |
| Bytes, those kinds, closure | 609.1 MB | 1,753.2 MB |
| Of the closure: `.olean` / `.olean.server` / `.olean.private` | 254.2 / 16.4 / 338.5 MB | 428.7 / 30.6 / 1,293.9 MB |
| Not shipped: `.ir` / `.ir.sig` of the closure | 25.5 / 0.1 MB | 354.4 / 0.4 MB |
| `bench-start`: import, then first load of a 20-line config (median of 5) | 159.6 ms, 14.2 ms | 426.0 ms, 14.9 ms |
| `bench-start`: real time (median of 5) | 0.21 s | 0.51 s |
| `bench-start`: largest maximum resident set (of 5) | 559.4 MB | 1,247.2 MB |

What the figures show:

- **The import reads three kinds of file.** With `.olean` alone it fails
  on `Init.olean.server`, and with `.olean.server` added on
  `Init.olean.private`; with both it imports and the config loads and runs.
  `.ir` and `.ir.sig` are never needed: compiled code is linked into the
  executable, and the fixture's command, which calls compiled code of
  `Init` and of `Editor`, runs without them. The editor
  package's own modules have only `.olean` files; the toolchain's use the
  module system, which reads all three. `.olean.private` is more than half
  of the bytes.
- **`Editor` reaches 139 of `Std`'s 494 modules and none of `Lean`'s.** Its
  closure is all of `Init`, those and 115 of the package's modules, 30%
  smaller than the whole directories.
- **With `Lean`, the bytes are 2.9 times, the start-up 2.4 times and the
  memory 2.2 times those of `Editor` alone.** The closure saves little
  there: `Lean` reaches all of `Std` and all of `Init`.

**The bundle shipped the closure of the set's base with `Std` and `Lean`**
(decided 2026-11-19, with config as modules; superseded on 2026-11-20 by
the whole toolchain, "The bundle with the toolchain, measured", below). Config is elaborated on the
set's base, `Editor` and then the entry module of each package of the
editor's set outside the core ([packages.md](packages.md), "The config base
of a set"): for the default set, `Editor`, `ShippedThemes.EditorPackage`
and `Compile.EditorPackage`. A config file may import any module of `Std`
or `Lean` beside it, and a bundled editor reads a module from the bundle
alone, so `:editorApp` took the closure of that base with
`Std` and `Lean` over the set's `.olean` directories, the core's and each
default package's, and staged it into the bundle's one directory
(the `stage-bundle` binary, `editor_release::bundle`, which takes the
package directories joined with `:` and copies a module from the first that
holds it). On 2026-11-19:

| | |
|---|---|
| Modules in the bundle | 2,501: `Init` 653, `Std` 494, `Lean` 1,227, `Editor` 117, `Compile` 6, `ShippedThemes` 4 |
| Module files, the three kinds | 1,760.1 MB (616.0 MB for the 919 modules of the base alone, before) |
| The bundle's headless mode, `env -i`, on a config that imports `Editor` alone (`tests/bench/generate`): real time (median of 5), largest maximum resident set | 0.24 s, 561.4 MB |
| The same on a config that imports `Lean` (`tests/headless/bundle`) | 0.71 s, 1,294.0 MB |

- **Carrying `Lean` costs disk, and start-up only for config that imports
  it.** The module files are 2.9 times what they were; an editor whose
  config does not import `Lean` starts as before and holds as much, since
  the base grows only when a file imports a module it does not hold.
- **The base does not start with everything linked.** Measured before the
  decision: a base of every linked module cost 0.61 s and 1.40 GB resident
  for each headless start against 0.23 s and 0.60 GB, which is also about
  25 s more on the gate's headless runs.
- **An editor reads a module of `Std` or `Lean` on its first import and
  never twice in a process**: growing the base read what the two add in
  165 ms and made the new environment in 154 ms in a prototype, with no
  doubling of memory, and the environment it grew from stayed usable.

### The bundle with the toolchain, measured

Since the packages roadmap's phase 9 the app ships the whole Lean
toolchain, the core and the default packages built, the Rust archive and
the link stubs, so a user's package set builds from the app alone ("The app
ships the toolchain"). That supersedes the closure-only bundle above, which
shipped the module files config's imports read and nothing a build needs:
a set's build needs `lake`, the linker, all of `Init`, `Std`, `Lean` and
`Lake` and the built core, so the closure no longer saves anything worth
its own staging. Measured on 2026-11-20, on an Apple M5 Max, macOS 27.2,
Lean 4.35.0, with

```sh
mise run app && mise run dmg && mise run bundle-bench
```

(`tools/bundle-bench.sh`; [on-demand-checks.md](../dev-practices/on-demand-checks.md),
"The bundle, measured on demand"). MB are 10⁶ bytes of apparent size. The
headless runs are the bundle's launcher with `env -i`, median of 5 and the
largest maximum resident set of 5, run twice; the same day `mise run
module-bench`'s staged closure-only bundle measured the same two configs
on the same editor, so the two columns differ by the layout alone, while
2026-11-19's figures are on the editor of that day.

| | With the toolchain (2026-11-20) | Closure only, same day (`module-bench`) | Closure only, 2026-11-19 |
|---|---|---|---|
| The toolchain (`lean/toolchain`) | 3,131.0 MB, 17,901 files | | |
| The core and the default packages, sources and build output (`lean/lean`, `lean/set`) | 385.5 MB, 3,928 files | | |
| The editor and the launcher (`Contents/MacOS`) | 239.6 MB | | |
| The Rust archive (`lean/target`) | 85.5 MB | | |
| The link stubs | 15 files, under 0.1 MB | | |
| The whole bundle | 3,848.6 MB, 21,854 files | not measured | 1,995 MB (module files 1,760.1 MB) |
| The disk image (`UDZO`) | 1,216,458,264 bytes, 56.6% of GitHub's 2 GiB asset limit | | |
| Headless start, a config of `Editor` alone (`tests/bench/generate`): real time, maximum resident set | 0.41 to 0.47 s, 609.8 MB | 0.39 s, 572.3 MB | 0.24 s, 561.4 MB |
| The same, a config that imports `Lean` (`tests/headless/bundle`) | 1.49 to 1.54 s, 1,452.1 MB | 1.16 s, 1,305.2 MB | 0.71 s, 1,294.0 MB |
| The unchanged default set's build from the bundle (`lake build :editorInstall`): first, with the core's lakefile elaborated; second | 10.6 to 11.8 s; 0.8 to 0.9 s | | |
| The build that installs `hello-init` from the bundle | 3.4 to 3.5 s | | |

What the figures show:

- **The image is well under the release-asset limit.** The toolchain is
  four fifths of the bundle, but packs to about a third of its size; the
  nightly refuses an image of 2 GiB or more (`ASSET_LIMIT` in
  `crates/editor-release`), and three levers remain if a later change
  needs room: `lib/` holds three identical copies of `libLLVM` and two of
  `libclang-cpp` (218 MB), `ULMO` packs tighter than `UDZO`, and the
  toolchain's `.ilean` and `src/` (117 MB) are not needed to build.
- **A build from the app compiles nothing it ships.** The unchanged set's
  first build is the elaboration of the core's lakefile into the config's
  `.lake`, the generated root's compile and the link; the second only
  links. A small package costs a few seconds more. Since the build's
  linters became a Lean plugin that every library loads (the library
  `Lint`, `lean/Lint/Wait.lean`), the plugin's trace is in every module's,
  so the bundle ships that library built too, its shared library among its
  files (`shipsLibrary`, `editorShipped` in `lean/lakefile.lean`): without
  it the build from the bundle would compile the plugin and every module
  after it.
- **Start-up and memory are a little higher than the closure's**, the same
  day: about 0.05 s and 38 MB for `Editor` alone, 0.35 s and 147 MB for a
  config that imports `Lean`. The modules imported are the same files; the
  cause was not looked into. The day's start-up times are all higher than
  2026-11-19's, the closure's too, so most of that change is the day's, not
  the layout's.

**A dynamically linked build saves disk and nothing else**, so there is none.
Lake has no option for one outside Windows; it would be link arguments of
our own. Measured once on macOS, by linking `editor` by hand both ways from
the same objects, against Lean's static libraries as the build does and
against its shared ones (`libInit_shared`, `libleanshared` and the two
beside it, found through an `-rpath` to the toolchain):

| | Static | Shared |
|---|---|---|
| Size | 181.6 MB | 4.5 MB |
| Link time | 0.25 s | 0.11 s |
| The demonstration, each of 20 runs | 19 ms | 32 ms |
| The headless fixture, each of 5 runs | 168 ms | 182 ms |
| Resident memory, the demonstration | 55.4 MB | 56.0 MB |
| Resident memory, the headless fixture | 419 MB | 416 MB |

Both print the same. The link is a quarter of a second either way, so a
shared build would not make the edit-and-run loop faster; it starts 13 ms
slower, and it would tie the executable to a toolchain directory.

## Open questions

- **Store design.** Whole-value cells are built. Keyed rows with per-row
  change events stay open, and so does how a command reaches more than one
  store. Decide from the first real users (evil's registers if config
  extends them, and third-party packages).
- **Third-party packages.** Loaded as interpreted modules at runtime, or
  compiled into a rebuilt executable (as xmonad does)? How they are fetched
  (Lake), and whether they are trusted like user config. Lean code runs
  with the user's full authority, as Emacs Lisp does. A constraint found
  with the config session: the base is safe to import beside a running
  editor thread only because every module in it is linked, so its
  initialisers are not run at import. An interpreted package's would be.
  Decided for Lean (packages phase 8): a user's packages are compiled into
  a rebuilt per-user executable, fetched by Lake with the system's git, and
  trusted like config ([packages.md](packages.md), "User package sets").
  For a package's Rust the decision and what is still refused are in
  [packages.md](packages.md), "Who can build it".
- **Overriding compiled features** beyond re-registration.
- **Memory growth** with many packages loaded and with background jobs
  holding old environments.
