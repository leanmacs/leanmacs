# compile

A default package: the compile mode. `:compile` runs a command in a
workspace's compilation buffer, `:next-error` and `:previous-error` step
through the locations its output names, and `:recompile` and
`:kill-compilation` run it again or stop it. It ships modes for cargo,
lake and mise, which offer their commands and read their tools' errors.

It is also a package with behaviour to read before writing one
([writing-a-package.md](../../docs/packages/writing-a-package.md)):
commands, a job over the process service, a major mode, ex names and
contributions. Its design record is in
[packages.md](../../docs/design/packages.md), "The default package
`compile`".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `compile`. It
   requires the core, `editor-core`, by path (`../../lean`), declares the
   library `Compile`, the test library `CompileTest` and the test driver
   `compile-test`, and turns every Lean linter on with warnings as errors.
   The library has `globs = ["Compile.*"]`: its root, `Compile.lean`, does
   not import the `Package` value or the entry module, and a library
   declared by its name alone would not hold them.
2. [`Compile/EditorPackage.lean`](Compile/EditorPackage.lean): the entry
   module. It imports `Compile.Compiled`, and so the whole library, which
   is what config sees of the package.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Compile.package]
   ```
3. [`Compile/Compiled.lean`](Compile/Compiled.lean): the `Package` value,
   `Editor.Compile.package`, named `compile`. Its `setup` registers nine
   commands with `commandWith`, the job `compile-run` with `workJob`, the
   mode `compilation` with `defineMode`, each shipped contribution with
   `compileContribution`, and six ex names with `exCommand`.
4. [`Compile.lean`](Compile.lean): the commands and the run. `compile`,
   `compile-command`, `recompile`, `kill-compilation`, the output's
   commands, the locations and the steps over them, and the mode
   `compilation`; each command's name is a declaration (`compileName` and
   the rest).
5. [`Compile/Errors.lean`](Compile/Errors.lean): the matcher. `scan` reads
   a tool's output with a list of formats into sites, with their paths,
   lines, columns and severities.
6. [`Compile/Shipped.lean`](Compile/Shipped.lean): the modes that ship,
   `cargoMode`, `lakeMode` and `miseMode`, collected in `shipped`, with
   rustc's and Lean's error formats, and `miseTasks`, which turns mise's
   task list into commands.
7. [`Compile/Contribution.lean`](Compile/Contribution.lean): what a
   workspace's contributions offer, and `formatsOf`, the formats in use.

Every declaration is in the namespace `Editor.Compile`, so config names
them as `Compile.cargoMode` under `open Editor`. The library imports only
modules of the core's API, two of them features still in the core: the
shell (`Editor.Shell`) and the workspace's modes
(`Editor.Workspace.Modes`).

## Its tests

- **The test driver**, [`CompileTest/Model.lean`](CompileTest/Model.lean),
  run by `lake test`: ten lists of model checks, in test modules that
  mirror the library's ([`CompileTest/Compile.lean`](CompileTest/Compile.lean)
  and those under [`CompileTest/Compile/`](CompileTest/Compile/)), written
  on the core's test kit (`Editor.Test`) and the support in
  [`CompileTest/Support/Compile.lean`](CompileTest/Support/Compile.lean).
- **The linked test**, [`CompileTest/Linked.lean`](CompileTest/Linked.lean),
  an executable linked as the editor is. It runs a compile over the real
  process service, a compile through a host on a stepped stage
  ([`CompileTest/Linked/Compile.lean`](CompileTest/Linked/Compile.lean)),
  and the shipped modes on a stepped rig
  ([`CompileTest/Linked/Compile/Shipped.lean`](CompileTest/Linked/Compile/Shipped.lean)),
  on the fixtures, canned output and trees in
  [`tests/compile/`](tests/compile/README).
- **The headless fixtures**, under [`tests/headless/`](tests/headless/):
  `ex-names`, each ex name reaching its command; `config`, a config written
  on the package's declarations; and `shipped-formats`, the shipped modes'
  formats reading canned output of cargo, lake and mise, with no process.

The gate runs all three kinds over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove compile` rebuilds your editor without it; `:compile` is
then not an ex command
([installing-packages.md](../../docs/packages/installing-packages.md)).
