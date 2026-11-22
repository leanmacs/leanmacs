# working-set

A default package: the working sets. `working-set-add` adds the selected
lines, or the cursor's line, of a file buffer, or a row of project search's
results, to a named set of the buffer's workspace; `working-set-open` opens
a set as an excerpt buffer of its ranges, which edit their files. In a
set's buffer `RET` visits a range, `d` removes it, `n` notes it, and the
refresh key fills the buffer again. Each range is kept with its text and
its context, so it is found again after its file changes; the sets are
written under the state directory with the commit `HEAD` is at, asked of
version control through `vc-api`. An editor without it has no
`working-set-add` or `working-set-open`, and keeps no sets.

Its design record is in [packages.md](../../docs/design/packages.md),
"The default packages of the features-as-packages roadmap's phase 6".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `working-set`. It
   requires its interface package, `working-set-api`
   ([`../working-set-api`](../working-set-api)), and the core,
   `editor-core`, by path (`../../lean`), declares the library
   `WorkingSet`, the test library `WorkingSetTest` and the test driver
   `working-set-test`, and turns every Lean linter on with warnings as
   errors.
2. [`WorkingSet/EditorPackage.lean`](WorkingSet/EditorPackage.lean): the
   entry module. It imports `WorkingSet.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.WorkingSet.package]
   ```
3. [`WorkingSet/Compiled.lean`](WorkingSet/Compiled.lean): the `Package`
   value, `Editor.WorkingSet.package`, named `working-set`: the commands
   under `working-set-api`'s names, the mode, the jobs and the hooks at
   `files-api`'s `Opened` and `Saved` and `buffers-api`'s `Closing`.
4. [`WorkingSet.lean`](WorkingSet.lean): a set's stored form.
5. [`WorkingSet/Refind.lean`](WorkingSet/Refind.lean): finding a range
   again in a changed file.
6. [`WorkingSet/Places.lean`](WorkingSet/Places.lean): where a range is
   held while the editor runs.
7. [`WorkingSet/Disk.lean`](WorkingSet/Disk.lean): the sets on disk.
8. [`WorkingSet/Run.lean`](WorkingSet/Run.lean): the commands.

The declarations keep their names, `Editor.WorkingSet.…`, from when they
were modules of the core.

## Its tests

- **The test driver**, [`WorkingSetTest/Model.lean`](WorkingSetTest/Model.lean),
  run by `lake test`: the working sets' model checks, one module under
  [`WorkingSetTest/`](WorkingSetTest) for each module of the library, on
  the working sets' driver,
  [`WorkingSetTest/Support/WorkingSet.lean`](WorkingSetTest/Support/WorkingSet.lean),
  and the core's kit.
- **The linked test**, [`WorkingSetTest/Linked.lean`](WorkingSetTest/Linked.lean),
  run by the package steps in `mise run ffi-test`: the working sets over
  the library's file service, fuzzy matcher and real git, through a
  restart, in
  [`WorkingSetTest/Linked/WorkingSet/Run.lean`](WorkingSetTest/Linked/WorkingSet/Run.lean).
- It has no headless fixture of its own. The core's
  `tests/headless/working-set-reopen` and
  `tests/headless/working-set-from-search`, run on the default set's
  editor, add, write and open sets through it.

## Dropping it

`:package-remove working-set` rebuilds your editor without it; the default
config's `SPC k a`, `SPC k o` and `SPC RET` then name commands no package
registers, unless your config registers commands under `working-set-api`'s
names ([installing-packages.md](../../docs/packages/installing-packages.md)).
