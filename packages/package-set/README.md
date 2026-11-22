# package-set

A default package: the commands that edit your package set, and the
registration of its build. `:package-install`, `:package-remove` and
`:package-update` edit your config's `lakefile.toml`, and a reload after
an edit builds the set and restarts into it. An editor without it has no
`:package-…` command, and a changed lakefile is not built: the job the
reload asks for is not registered. You then edit the lakefile by hand and
build the set with `lake` yourself
([installing-packages.md](../../docs/packages/installing-packages.md)).

Its design record is in [packages.md](../../docs/design/packages.md),
"User package sets".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `package-set`. It
   requires the core, `editor-core`, by path (`../../lean`), declares the
   library `PackageSet`, the test library `PackageSetTest` and the test
   driver `package-set-test`, and turns every Lean linter on with warnings
   as errors.
2. [`PackageSet/EditorPackage.lean`](PackageSet/EditorPackage.lean): the
   entry module. It imports `PackageSet.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.PackageSet.package]
   ```
3. [`PackageSet/Compiled.lean`](PackageSet/Compiled.lean): the three
   commands, the job `package-edit` that writes an edited lakefile, and
   the `Package` value, `Editor.PackageSet.package`, named `package-set`.

What it registers and edits through is the core's
(`lean/Editor/PackageSet/`): the build job `package-build` and the two
commands it posts to (`Build.lean`), the edits of a lakefile
(`Edit.lean`), the fingerprint (`Fingerprint.lean`) and what a running
editor knows of its set (`Running.lean`). The reload asks for a build and
the hosts start the job by its name, which the core declares, so they
name nothing of this package. Its declarations keep their names
(`Editor.PackageSet.…`) from when it was a module of the core.

## Its tests

- **The test driver**, [`PackageSetTest/Model.lean`](PackageSetTest/Model.lean),
  run by `lake test`: `packageSetCommandChecks`, in
  [`PackageSetTest/PackageSet/Compiled.lean`](PackageSetTest/PackageSet/Compiled.lean),
  which mirrors the library module: the three commands' edits and
  refusals, on the core's test kit, and what the package registers, held
  to the kit's stand-in for the build.
- **End to end**: the user sets test
  ([the-gate.md](../../docs/dev-practices/the-gate.md), "The user sets
  test") removes a package
  with `:package-remove` on an editor built from the default set, and
  restarts into the build.

The gate runs the driver over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove package-set` rebuilds your editor without it, once: the
editor it restarts into has no `:package-…` command and builds no changed
lakefile. To get it back, add its require to your `lakefile.toml` by hand
and build the set with `lake`
([installing-packages.md](../../docs/packages/installing-packages.md)).
