# binding-search

A default package: the binding search. `search-bindings` asks
`Binding: ` for one of the key bindings the input scheme reaches in the
asking view, each shown as its keys and command with its description, and
runs the one accepted as its key would, as Embark's `embark-bindings` and
Doom's `SPC h b b` do. The default config binds it to `SPC ?`.

It implements the interface package
[`binding-search-api`](../binding-search-api/), which declares the name it
is registered under. Its design record is in
[packages.md](../../docs/design/packages.md), "The default package
`binding-search`".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `binding-search`.
   It requires the core, `editor-core`, by path (`../../lean`), and the
   interface package `binding-search-api` (`../binding-search-api`),
   declares the library `BindingSearch`, the test library
   `BindingSearchTest` and the test driver `binding-search-test`, and
   turns every Lean linter on with warnings as errors.
2. [`BindingSearch/EditorPackage.lean`](BindingSearch/EditorPackage.lean):
   the entry module. It imports `BindingSearch.Compiled`, and so the whole
   library, which is what config sees of the package.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.BindingSearch.package]
   ```
3. [`BindingSearch/Compiled.lean`](BindingSearch/Compiled.lean): the
   `Package` value, `Editor.BindingSearch.package`, named
   `binding-search`. Its `setup` registers the command with `commandWith`
   and its completion source, `bindings`, with `defineSource`.
4. [`BindingSearch.lean`](BindingSearch.lean): the command
   (`searchBindings`), its source of the bindings the scheme reaches
   (`source`, `candidate`), and how an answer is resolved (`resolve`). The
   name it registers under, `name`, is
   `BindingSearchApi.searchBindingsName`.

Every declaration is in the namespace `Editor.BindingSearch`, where it was
in the core, so config names them as `BindingSearch.searchBindings` under
`open Editor`, with `import BindingSearch`. The library imports the core's
API alone, and the interface package.

## Its tests

- **The test driver**, [`BindingSearchTest/Model.lean`](BindingSearchTest/Model.lean),
  run by `lake test`: `bindingSearchChecks`, in
  [`BindingSearchTest/BindingSearch.lean`](BindingSearchTest/BindingSearch.lean),
  on the core's test kit, and `bindingSearchPackageChecks`, in
  [`BindingSearchTest/BindingSearch/Compiled.lean`](BindingSearchTest/BindingSearch/Compiled.lean),
  the interface's contract check over the `Package` value.
- **The headless fixture**, [`tests/headless/binding-search`](tests/headless/binding-search/):
  config's binding listed with its keys, command and description, run as
  its key would, and a config command that names `BindingSearch.label`.
  It was written on the editor with the binding search still in the core
  and moved here with one line changed, its config's import.

The gate runs both over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove binding-search` rebuilds your editor without it; `SPC ?`
then runs a name no package registers
([installing-packages.md](../../docs/packages/installing-packages.md)).
