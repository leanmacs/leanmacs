# files

A default package: the file commands. `open-file` opens a file into a
buffer, asking for its path with a prompt over the file source when it is
given none; `save-buffer` writes a buffer to its file; `edit-file` opens
again, `reload-buffer` reloads a buffer from disk, and `auto-reload-mode`
follows a file that changes on disk. It registers the jobs they start, the
jobs the loop starts under the core's names to check and follow open files
(`check-files`, `follow-file`), the file source `files` with the path style
as the category `file`'s default, and the value of the interface library
`files-api` (`FilesApi.Files`), through which session restore, the jump
commands, ex and the menu open and save files. An editor without it opens
no file named on its command line and has no `save-buffer`.

Its design record is in [packages.md](../../docs/design/packages.md),
"The default packages of the features-as-packages roadmap's phase 6".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `files`. It requires
   the core, `editor-core`, by path (`../../lean`), declares the library
   `Files`, the test library `FilesTest` and the test driver `files-test`,
   and turns every Lean linter on with warnings as errors.
2. [`Files/EditorPackage.lean`](Files/EditorPackage.lean): the entry
   module. It imports `Files.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Files.package]
   ```
3. [`Files/Compiled.lean`](Files/Compiled.lean): the `Package` value,
   `Editor.Files.package`, named `files`: the commands under `files-api`'s
   names, their jobs, the file source and the `FilesApi.Files` value.
4. [`Files.lean`](Files.lean): the commands and their jobs, written over
   the core's editor API and its file port.
5. [`Files/Paths.lean`](Files/Paths.lean): the file source, which lists a
   directory's entries for the open prompt.

The names are the core's interface library `files-api`'s
(`lean/FilesApi.lean`), a core interface for good. The declarations keep
their names, `Editor.Files.…` and `Editor.Completion.Paths.…`, from when
they were modules of the core.

## Its tests

- **The test driver**, [`FilesTest/Model.lean`](FilesTest/Model.lean), run
  by `lake test`: the files' model checks, in
  [`FilesTest/Files.lean`](FilesTest/Files.lean),
  [`FilesTest/Files/Compiled.lean`](FilesTest/Files/Compiled.lean) and
  [`FilesTest/Files/Paths.lean`](FilesTest/Files/Paths.lean), on the
  files' test kit, [`FilesTest/Kit.lean`](FilesTest/Kit.lean).
- **The linked test**, [`FilesTest/Linked.lean`](FilesTest/Linked.lean),
  run by the package steps in `mise run ffi-test`: the files through the
  headless host over the real elaborator and the library's file and watch
  services, in [`FilesTest/Linked/Files.lean`](FilesTest/Linked/Files.lean).
- It has no headless fixture of its own. The core's
  `tests/headless/open-file` and `tests/headless/files`, run on the default
  set's editor, open and save files through it.

## Dropping it

`:package-remove files` rebuilds your editor without it; it then opens no
file and saves none, unless your config registers commands under
`files-api`'s names
([installing-packages.md](../../docs/packages/installing-packages.md)).
