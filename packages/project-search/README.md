# project-search

A default package: project search. `project-search` searches a
workspace's files for a pattern, by the core's rule of what is searched,
into an editable excerpt buffer of the matches: an edit typed over a match
changes that file's buffer, and `RET` on a match visits it.
`project-search-symbol` searches the word under the cursor. Files open
through the core's interface library `files-api`. An editor without it has
no `project-search` or `project-search-symbol`.

Its design record is in [packages.md](../../docs/design/packages.md),
"The default packages of the features-as-packages roadmap's phase 6".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `project-search`. It
   requires its interface package, `project-search-api`
   ([`../project-search-api`](../project-search-api)), and the core,
   `editor-core`, by path (`../../lean`), declares the library
   `ProjectSearch`, the test library `ProjectSearchTest` and the test driver
   `project-search-test`, and turns every Lean linter on with warnings as
   errors.
2. [`ProjectSearch/EditorPackage.lean`](ProjectSearch/EditorPackage.lean):
   the entry module. It imports `ProjectSearch.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.ProjectSearch.package]
   ```
3. [`ProjectSearch/Compiled.lean`](ProjectSearch/Compiled.lean): the
   `Package` value, `Editor.ProjectSearch.package`, named `project-search`:
   the commands under `project-search-api`'s names, the results mode and
   the jobs.
4. [`ProjectSearch.lean`](ProjectSearch.lean): the search's pure core, the
   rows an excerpt shows and the record a result is kept in.
5. [`ProjectSearch/Run.lean`](ProjectSearch/Run.lean): the commands and the
   jobs, over the core's grep port.

The declarations keep their names, `Editor.ProjectSearch.…`, from when
they were modules of the core.

## Its tests

- **The test driver**, [`ProjectSearchTest/Model.lean`](ProjectSearchTest/Model.lean),
  run by `lake test`: project search's model checks, one module under
  [`ProjectSearchTest/`](ProjectSearchTest) for each module of the library,
  on the core's kit under the test scheme.
- **The linked test**, [`ProjectSearchTest/Linked.lean`](ProjectSearchTest/Linked.lean),
  run by the package steps in `mise run ffi-test`: project search over the
  library's grep service, file service and text store, in
  [`ProjectSearchTest/Linked/ProjectSearch/Run.lean`](ProjectSearchTest/Linked/ProjectSearch/Run.lean).
- No module of the package, its library or its tests, reaches a module of
  evil.
- It has no headless fixture of its own. The core's
  `tests/headless/working-set-from-search`, run on the default set's
  editor, searches through it.

## Dropping it

`:package-remove project-search` rebuilds your editor without it; the
default config's `SPC /`, `SPC s p` and `SPC *` then name commands no
package registers, unless your config registers commands under
`project-search-api`'s names
([installing-packages.md](../../docs/packages/installing-packages.md)).
