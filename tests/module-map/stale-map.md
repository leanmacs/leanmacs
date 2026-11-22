# The module map of the fixture packages

The map that `tools/module-map-check.sh --points` is held to in `mise run
lean-test` (docs/dev-practices/the-gate.md, "The module map check"): the
library modules under `packages/` here hold exactly the registrations and
reads its rows name, so the check prints nothing and exits 0. `stale-map.md`
is the same map with one registration dropped and one read added, and the
check must print exactly `stale-expected` and exit 1.

Only the rows of the section "The packages" are read, and of a row only
its fourth and fifth columns. The row below is before that section.

| `early` | implementation | none | `Skipped.Early` | none | a row before the section |

### The packages

| Package | Layer | Requires | Registers at | Reads | What else |
|---|---|---|---|---|---|
| `buffers-api` | interface | none | none | `FilesApi.Files` | declares `BuffersApi.Buffers` and `BuffersApi.Closing` |
| `sample` | implementation | `buffers-api` | `FilesApi.Opened`, `Compile.Contribution`, `Compile.ProjectCommands` | `FilesApi.Files`, `Skipped.Gone`, `ProjectApi.Workspaces`, `Sample.Choice`, `Sample.Work`, `FilesApi.Saved`, `BuffersApi.Closing`, `Compile.Contribution`, `Compile.ProjectCommands` | a last column that names `Skipped.Note` |

### After the packages

| `late` | implementation | none | `Skipped.Late` | none | a row after the section |
