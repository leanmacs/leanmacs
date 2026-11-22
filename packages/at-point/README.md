# at-point

A default package: completion at point, after Doom Emacs's corfu module.
Its commands ask for candidates for the text before the cursor, move the
choice, preview it in the region, accept it and quit; the Vim scheme binds
them in insert state (`C-SPC`, `C-n`, `C-p`, `TAB`, `S-TAB`, `RET`,
`C-g`). Its source, `words`, completes from the words of the open buffers,
as Vim's `C-n` does, from a job, and asks by itself after a pause of 240 ms
once two characters are typed. Config tunes it by defining it again
(`defineAtPoint (Completion.AtPoint.words (pause := 100))`).

It implements the interface package [`at-point-api`](../at-point-api/),
which declares the names of its nine commands: the seven the Vim scheme's
insert table binds, and the two the core runs by itself at a typed trigger
and at a pause. Its design record is in
[packages.md](../../docs/design/packages.md), "The default packages of
the features-as-packages roadmap's phase 4".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `at-point`. It
   requires the core, `editor-core`, by path (`../../lean`), and the
   interface package `at-point-api` (`../at-point-api`), declares the
   library `AtPoint`, the test library `AtPointTest` and the test driver
   `at-point-test`, and turns every Lean linter on with warnings as
   errors.
2. [`AtPoint/EditorPackage.lean`](AtPoint/EditorPackage.lean): the entry
   module. It imports `AtPoint.Compiled`, and so the whole library, which
   is what config sees of the package.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.AtPoint.package]
   ```
3. [`AtPoint/Compiled.lean`](AtPoint/Compiled.lean): the `Package` value,
   `Editor.AtPoint.package`, named `at-point`. Its `setup` registers the
   nine commands, the job of `words`, the source `words` and the at-point
   source `words`, and uses `words` for every buffer.
4. [`AtPoint.lean`](AtPoint.lean): the commands, each over the core's API
   ("Completion at point", `lean/Editor/Api.lean`). Their names are
   `at-point-api`'s (`AtPointApi.completeName`, …).
5. [`AtPoint/Words.lean`](AtPoint/Words.lean): the words of a text, their
   order, the source and its job, and the at-point source.

Every declaration is in the namespace it had in the core, `Editor.AtPoint`
for the commands and `Editor.Completion` for `words`, so config names
them as `Completion.AtPoint.words` under `open Editor`, with
`import AtPoint.Words`. The library imports the core's API, its completion
at point interfaces (`Editor.Completion.AtPoint`, `Editor.Completion.Later`)
and the interface package.

## Its tests

- **The test driver**, [`AtPointTest/Model.lean`](AtPointTest/Model.lean),
  run by `lake test`: `atPointChecks`
  ([`AtPointTest/AtPoint.lean`](AtPointTest/AtPoint.lean)), the commands
  on a driver of the Vim scheme over the models, `wordsChecks`
  ([`AtPointTest/AtPoint/Words.lean`](AtPointTest/AtPoint/Words.lean)),
  the source on the job model and the at-point sources' contract, and
  `atPointPackageChecks`
  ([`AtPointTest/AtPoint/Compiled.lean`](AtPointTest/AtPoint/Compiled.lean)),
  the interface's contract check over the `Package` value. Their support
  is [`AtPointTest/Support/Words.lean`](AtPointTest/Support/Words.lean).
- **The headless fixtures**, [`tests/headless/at-point`](tests/headless/at-point/)
  (the pause, the preview and the accept through the host, on a copy of
  the shared config it ran on in the core) and
  [`tests/headless/at-point-tuned`](tests/headless/at-point-tuned/)
  (config tunes `words`' pause). They were written on the editor with
  completion at point still in the core and moved here, the second with
  one line changed, its config's import.

The gate runs both kinds over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove at-point` rebuilds your editor without it. Nothing then
completes at point, and insert state's `RET`, `TAB` and `C-g`, which the
Vim scheme binds to this package's commands, do nothing: with no session
open those commands are what type a line feed or a tab and quit.
