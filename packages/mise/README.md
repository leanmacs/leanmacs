# mise

A default package: mise as a child's directory environment source. In the
window mode, a child started in a directory gets what `mise env --json`
sets there (its `PATH` first), layered over the base, the editor's own
environment unless another base is chosen. mise is found at the first of
`~/.local/bin/mise`, `/opt/homebrew/bin/mise` and `/usr/local/bin/mise`,
never by bare name; the result is kept until one of mise's config files
(`mise.toml`, `.mise.toml`, `.tool-versions`, `mise.local.toml`) in the
directory or an ancestor changes, or a reload. The headless mode looks
nothing up. An editor without it does no directory lookup: children start
with the editor's own environment.

Its design record is in
[packages.md](../../docs/design/packages.md), "The core interface library
`environment-api`", and the layers it joins in
[concurrency.md](../../docs/design/concurrency.md), "A child's environment,
as built".

## Its setting

```lean
def setup : SetupM Unit := do
  Mise.executable "/opt/homebrew/bin/mise"
```

runs mise at that absolute path, in every mode, in place of looking in the
usual places. It replaces the retired
`processEnvironment (.mise (some path))`; leaving the package out replaces
`processEnvironment .inherited`.

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `mise`. It requires
   the core, `editor-core`, by path (`../../lean`), whose Lake package
   holds the interface library it implements, `EnvironmentApi`; declares
   the library `Mise`, the test library `MiseTest` and the test driver
   `mise-test`; and turns every Lean linter on with warnings as errors.
2. [`Mise/EditorPackage.lean`](Mise/EditorPackage.lean): the entry
   module. It imports `Mise.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Mise.package]
   ```
3. [`Mise/Compiled.lean`](Mise/Compiled.lean): the `Package` value,
   `Mise.package`, named `mise`: it registers `Mise.directorySource` at
   `EnvironmentApi.DirectorySource`.
4. [`Mise.lean`](Mise.lean): the source as data (the candidates, the
   lookup's command, the stamp names), the value the package registers, and
   the setting, `Mise.executable`.

## Its tests

- **The test driver**, [`MiseTest/Model.lean`](MiseTest/Model.lean), run
  by `lake test`: the registration, the setting and the source, and
  `environment-api`'s contract on the model rig, in
  [`MiseTest/Mise.lean`](MiseTest/Mise.lean), with the lookup checks that
  were the core's.
- **The linked test**, [`MiseTest/Linked.lean`](MiseTest/Linked.lean), run
  by the package steps in `mise run ffi-test`: `environment-api`'s
  directory-source contract over the library's process service, in
  [`MiseTest/Linked/Mise/Contract.lean`](MiseTest/Linked/Mise/Contract.lean),
  with the fixtures under
  [`tests/process-environment`](tests/process-environment) standing in for
  mise.
- It has no headless fixture of its own.

## Dropping it

`:package-remove mise` rebuilds your editor without it; children then
start with the editor's own environment, plus what the base adds
([installing-packages.md](../../docs/packages/installing-packages.md)).
