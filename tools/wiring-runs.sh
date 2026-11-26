#!/bin/sh
# The CLI's runs and the window scenarios of the wiring set, one case each,
# called once by the gate (`mise run ffi-test`) and once a round by the
# stress loop (`tools/stress.sh`, its `ffi-wiring` and `cli-wiring` suites)
# (docs/dev-practices/real-thread-checks.md, "How the set runs"):
#
#   tools/wiring-runs.sh prepare <dir>
#   tools/wiring-runs.sh run <dir> [fixtures|scenarios]
#
# Run it in `lean/`, after the gate's builds; it builds nothing but what
# `prepare` stages. Each case runs a real-thread entry whose site is
# ffi-test (`Editor.Test.Fixture.RealThread.entries`, the CLI over a real
# loop thread), named in the comment above it by its script, or a window
# scenario of ffi-test (`FfiTest.windowScenarios`), named by its
# subcommand; a case may cover several entries that one run of the CLI
# covers, as the runner entries' comparison does. Each case's commands are
# the gate's lines they were, moved here as they were written, each in a
# shell of its own, with errexit, as mise runs a task's line. That each
# entry and scenario at ffi-test has its case is a reviewer rule
# (`.agents/rules/structure.md`, "The wiring set's runs"), which
# `fixture-test real-thread --site ffi-test` and `ffi-test
# wiring-scenarios` list for.
#
# - `prepare <dir>` stages into `<dir>` what a case builds before its run:
#   the greeting entry's install of the fixture set (`:editorInstall`).
#   Run once, before the runs, so a stress round builds nothing.
# - `run <dir>` runs every case, or the group named, over what `prepare`
#   staged in `<dir>`. It runs every case though one fails, names each
#   that failed, and exits 1 when one did: each case passes or fails by
#   its status alone. A case fails when any of its steps fails, not only
#   its last: it runs with errexit, as a command of its own, never as a
#   condition.
set -eu

usage() {
  echo "usage: tools/wiring-runs.sh prepare <dir> | run <dir> [fixtures|scenarios]" >&2
  exit 2
}

# The cases: each one's group and its name (the function case_<name> runs
# it), separated by a tab. The comment above each case names the entries or
# the scenario it runs.
table() {
  cat <<'TABLE'
fixtures	compare
fixtures	dispatch
fixtures	needs_rebuild
fixtures	generate
fixtures	default_config
fixtures	no_input_scheme
fixtures	restore_abort
fixtures	restore_changed
fixtures	restore_quit
fixtures	restore_newer
fixtures	restore_layout
fixtures	restore_stores
fixtures	restart
fixtures	restart_probe
fixtures	restart_fallback
fixtures	open_file
fixtures	milestone
scenarios	window_host
scenarios	window_host_config
scenarios	window_host_restart
scenarios	window_host_base
scenarios	window_host_generate
scenarios	window_host_direct
scenarios	window_host_undrawn
fixtures	greeting
TABLE
}

# tests/headless/script, tests/headless/keys-script, tests/headless/scene-script, tests/headless/ex/script
case_compare() {
  # The fixtures whose subject is the script runner over a real loop thread
  # (docs/dev-practices/real-thread-checks.md, "The CLI's runs in the
  # gate"), the real-thread set's runner entries, run both ways and
  # compared. The list is the harness's, from the module (`fixture-test …
  # compared`, one `<script>\t<config>\t<expected>` a line). Each is run
  # through the CLI, `editor headless`, over a real loop thread, which must
  # exit 0, and its output handed to the harness (`fixture-test … compare
  # <script> <file>`), which runs it stepped and exits 1, saying the lines
  # each side alone has, when the two outputs differ or are not the
  # fixture's expected file. The case passes or fails by those statuses
  # alone; nothing reads what they print to decide. When one fails, what it
  # printed is shown, with a line naming the command, its status and the
  # script, for people reading the log. The CLI runs here, in shell, because
  # Lean spawns no child process (docs/design/overview.md, "Rules of the
  # boundary").
  (
    set -e
    editor=../packages/.lake/build/bin/editor
    harness=../packages/.lake/build/bin/fixture-test
    sysroot=$(lean --print-prefix)
    oleans=.lake/build/lib/lean
    repo=$(cd .. && pwd -P)
    status=0
    list=$("$harness" "$sysroot" "$oleans" --repo "$repo" compared) || status=$?
    if [ "$status" -ne 0 ]; then
      printf '%s\n' "$list"
      echo "wiring-runs: compare: fixture-test … compared exited $status" >&2
      exit 1
    fi
    out=$(mktemp)
    trap 'rm -f "$out"' EXIT
    # The list is read on a descriptor of its own, so that neither run can
    # take it for its input.
    while IFS=$tab read -r script config _ <&3; do
      [ -n "$script" ] || continue
      status=0
      "$editor" headless "$sysroot" "$oleans" "$repo/$config" "$repo/$script" >"$out" || status=$?
      if [ "$status" -ne 0 ]; then
        cat "$out"
        echo "wiring-runs: compare: the CLI exited $status on $script" >&2
        exit 1
      fi
      status=0
      "$harness" "$sysroot" "$oleans" --repo "$repo" compare "$script" "$out" || status=$?
      if [ "$status" -ne 0 ]; then
        echo "wiring-runs: compare: fixture-test … compare exited $status on $script" >&2
        exit 1
      fi
    done 3<<LIST
$list
LIST
  )
}

# tests/headless/dispatch/script
case_dispatch() {
  # Keys dispatched to commands, on a config of its own (tests/headless/
  # dispatch): a key sequence config binds runs its command, the interrupt
  # key stops one that loops over requests and rolls back its edit, the next
  # key's command runs to its end, and a key's command starts a job with an
  # argument, whose result the job's command says in the echo area
  # (`dispatch/expected`). A command that is not stopped loops for longer
  # than the time limit.
  (
    set -e
    out=$(../packages/.lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/dispatch/config ../tests/headless/dispatch/script) && printf '%s\n' "$out" | diff ../tests/headless/dispatch/expected -
  )
}

# tests/headless/needs-rebuild/script
case_needs_rebuild() {
  # A module of a package the config's lakefile names
  # (tests/headless/needs-rebuild): the root imports `Greeting`, and the
  # directory's `lakefile.toml` requires the fixture package `greeting`. On
  # the default set's editor, which does not link that package, the reload
  # is rejected and the diagnostic names the package and says the package
  # set needs a rebuild (`needs-rebuild/expected`); on the fixture set's
  # editor, which links it, the config loads and the package's command runs
  # (`needs-rebuild/installed-expected`). The headless mode is run with no
  # `--generate`, so it reads the fixture's lakefile and writes nothing: the
  # third line fails if the fixture's config directory holds anything but
  # its two tracked files.
  (
    set -e
    out=$(../packages/.lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/needs-rebuild/config ../tests/headless/needs-rebuild/script) && printf '%s\n' "$out" | diff ../tests/headless/needs-rebuild/expected -
  )
  (
    set -e
    out=$(../tests/packages/.lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/needs-rebuild/config ../tests/headless/needs-rebuild/script) && printf '%s\n' "$out" | diff ../tests/headless/needs-rebuild/installed-expected -
  )
  (
    set -e
    test "$(ls -A ../tests/headless/needs-rebuild/config | tr '\n' ' ')" = 'init.lean lakefile.toml '
  )
}

# tests/headless/generate/script
case_generate() {
  # The config directory as a Lake package (tests/headless/generate, whose
  # config directory holds `init.lean` alone): on a temporary copy, the
  # default set's `editor headless --generate` creates `lean-toolchain`,
  # equal to `lean/lean-toolchain`, and a `lakefile.toml` that requires the
  # set by its directory, and the config loads; a second run rewrites
  # neither; and a run without `--generate` on another copy writes neither.
  # Then Lean's language server, started in the directory the first run
  # generated, with the root and the config file of
  # tests/config-package/lsp put in it: the root imports `Lean`, `Compile`
  # and `Config.Keys` and holds one type error, and the server must report
  # that error, at 8:19, and no other, so no import failed
  # (`config-test lsp`, lean/ConfigTest/Lsp.lean). It takes about three
  # seconds, needs no network, and writes in the temporary directory alone
  # (tools/config-package-check.sh). The two lines it prints are required.
  (
    set -e
    out=$(sh ../tools/config-package-check.sh ../packages "$(lean --print-prefix)" .lake/build/lib/lean) || { printf '%s\n' "$out"; exit 1; }; printf '%s\n' "$out"; for line in 'config-package: generated lakefile.toml and lean-toolchain, the config loaded, and a second run wrote nothing' 'config-test lsp: init.lean: no import error, and the type error is at 8:19'; do printf '%s\n' "$out" | grep -qxF "$line" || { echo "config-package-check did not print: $line" >&2; exit 1; }; done
  )
}

# tests/headless/default-config/script
case_default_config() {
  # The default config `mise run install` ships (config/default), on the
  # editor of the default set (tests/headless/default-config): the binding
  # search lists its `SPC f f  open-file`, and `SPC :` and `SPC ?`, run
  # from the search as their keys would run, open the command prompt and
  # the binding search; its file, buffer, workspace, search and working-set
  # keys are listed, and each run from the search opens its prompt or says
  # why it cannot (`default-config/expected`). The config is copied into a
  # temporary directory, which a trap removes, so nothing is written into
  # the checkout, and the editor runs in an empty directory beside it, so
  # the prompts that start at the working directory, or search it, are the
  # same everywhere once the directory's path, taken physically, is written
  # `@DIR@`. The workspace finder's keys run the default source, whose
  # filter is `fzf`, which the gate does not install: for this one run the
  # fixture that stands in for it (tests/completion/filter) is first on the
  # editor's `PATH` under that name, in the temporary directory, so the
  # run is the same where fzf is installed and where it is not.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && dir=$(cd "$dir" && pwd -P) && root=$(pwd) && prefix=$(lean --print-prefix) && cp -R ../config/default "$dir/config" && mkdir "$dir/cwd" "$dir/bin" && cp ../tests/completion/filter "$dir/bin/fzf" && out=$(cd "$dir/cwd" && PATH="$dir/bin:$PATH" "$root/../packages/.lake/build/bin/editor" headless "$prefix" "$root/.lake/build/lib/lean" "$dir/config" "$root/../tests/headless/default-config/script") && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | diff ../tests/headless/default-config/expected -
  )
}

# tests/headless/no-input-scheme/script
case_no_input_scheme() {
  # An editor of a set with no input-scheme package refuses to start
  # (tests/headless/no-input-scheme), run on the editor built from the set
  # tests/empty-set, which is the default set with its packages dropped:
  # the Vim scheme is the default package evil's (packages/evil/), so no
  # package of that set supplies a scheme (`Editor.Main.run`,
  # docs/design/packages.md, "Input schemes"). The headless mode must exit
  # 1 having printed exactly `no-input-scheme/expected`, the one line
  # `editor: no input scheme is installed: no package of this editor's
  # package set supplies one`, before it reads the script or loads the
  # config; and so must `--probe`, which a restart runs before it hands
  # the session over, so that a restart into such a set is given up. Any
  # other status or text fails. It touches no file. The two fixtures that
  # ran on this editor while the core supplied the scheme, core-themes and
  # core-ex-names, are retired: where what they showed of an editor
  # without the default packages is held is in docs/design/packages.md,
  # "Dropping evil or themes leaves…".
  (
    set -e
    status=0; out=$(../tests/empty-set/.lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/no-input-scheme/config ../tests/headless/no-input-scheme/script 2>&1) || status=$?; test "$status" -eq 1 && printf '%s\n' "$out" | diff ../tests/headless/no-input-scheme/expected -
  )
  (
    set -e
    status=0; out=$(../tests/empty-set/.lake/build/bin/editor --probe 2>&1) || status=$?; test "$status" -eq 1 && printf '%s\n' "$out" | diff ../tests/headless/no-input-scheme/expected -
  )
}

# tests/headless/restore/abort-script, tests/headless/restore/restore-script
case_restore_abort() {
  # Session restore, as a process, with `--state` naming a directory of
  # the step's (tests/headless/restore; docs/dev-practices/the-gate.md, the
  # session restore entries). Each run's output has the temporary
  # directory's path written `@DIR@`, a stamp's time `@TIME@`, and its job
  # lines and command list dropped: what a job came to is printed when its
  # wake-up arrives, which the other events do not wait for. An abort: the
  # script types into a file, waits until the journal is written and ends
  # with the status 134 and no shutdown; a second run with the same state
  # directory restores the text, modified (`restore-expected`).
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && f=../tests/headless/restore && cp $f/note.txt "$dir/note.txt" && sed "s|@FILE@|$dir/note.txt|" $f/abort-script > "$dir/abort" && status=0 && { ../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/abort" > /dev/null || status=$?; } && test "$status" -eq 134 && out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config $f/restore-script) && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | grep -v '^job \|^commands:' | diff $f/restore-expected -
  )
}

# tests/headless/restore/changed-script
case_restore_changed() {
  # The same abort, the file rewritten by another program between the runs:
  # the buffer comes back marked changed on disk, `:w` is refused as
  # changed, and the file is left as the other program wrote it.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && f=../tests/headless/restore && cp $f/note.txt "$dir/note.txt" && sed "s|@FILE@|$dir/note.txt|" $f/abort-script > "$dir/abort" && status=0 && { ../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/abort" > /dev/null || status=$?; } && test "$status" -eq 134 && printf 'rewritten\n' > "$dir/note.txt" && out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config $f/changed-script) && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g; s/modified at [0-9]* s and [0-9]* ns/modified at @TIME@/" | grep -v '^job \|^commands:' | diff $f/changed-expected - && printf 'rewritten\n' | cmp "$dir/note.txt" -
  )
}

# tests/headless/restore/quit-script
case_restore_quit() {
  # A clean quit: edit, `:w`, `:q`. Afterwards the journals' directory is
  # empty and this run's index says it ended, and the next run restores
  # nothing (`quit-restore-expected`).
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && f=../tests/headless/restore && cp $f/note.txt "$dir/note.txt" && sed "s|@FILE@|$dir/note.txt|" $f/quit-script > "$dir/quit" && out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/quit") && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | grep -v '^job \|^commands:' | diff $f/quit-expected - && test -z "$(ls -A "$dir/state/session/journals")" && grep -q '"ended":true' "$dir/state/session/session-1.json" && out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config $f/restore-script) && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | grep -v '^job \|^commands:' | diff $f/quit-restore-expected -
  )
}

# tests/headless/restore/newer-script
case_restore_newer() {
  # Another version's session: an index of format 99 with keys this editor
  # does not know, and a journal with a record of a kind it does not know
  # (tests/headless/restore/newer). The known part is restored, the report
  # says the rest and the editor starts; afterwards both files are as they
  # were, byte for byte.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && f=../tests/headless/restore && cp -R $f/newer "$dir/state" && out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config $f/newer-script) && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | grep -v '^job \|^commands:' | diff $f/newer-expected - && cmp "$dir/state/session/session-5.json" $f/newer/session/session-5.json && cmp "$dir/state/session/journals/5-1-1.log" $f/newer/session/journals/5-1-1.log && cmp "$dir/state/session/journals/5-1-1.base" $f/newer/session/journals/5-1-1.base
  )
}

# tests/headless/restore/layout-script, tests/headless/restore/layout-restore-script
case_restore_layout() {
  # Phase 2 of session restore: windows, layouts, tabs and the jump list
  # (tests/headless/restore/layout-*). The save run, against `layout-config`,
  # makes two tabs of manual splits at a left edge with a docked window, a
  # float and a named, zoomed tab, records jumps, types, waits for the index
  # (`indexed`) and the journal, and aborts (`layout-expected`); the restore
  # run puts them back as they were, held before config installs and kept
  # after, `C-w n` shows the hidden tab, `C-o` the recorded jump, and `u`
  # says the history starts at the restore (`layout-restore-expected`). The
  # index it writes is of format 2.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && f=../tests/headless/restore && cp $f/note.txt "$dir/note.txt" && sed "s|@FILE@|$dir/note.txt|" $f/layout-script > "$dir/layout" && status=0 && { out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean $f/layout-config "$dir/layout") || status=$?; } && test "$status" -eq 134 && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | grep -v '^job \|^commands:' | diff $f/layout-expected - && out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean $f/layout-config $f/layout-restore-script) && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | grep -v '^job \|^commands:' | diff $f/layout-restore-expected - && grep -q '"format":2' "$dir/state/session/session-2.json"
  )
}

# tests/headless/restore/stores-script, tests/headless/restore/stores-restore-script
case_restore_stores() {
  # Phase 2 of session restore: stores, workspaces and jobs
  # (tests/headless/restore/stores-*). A `.project` marker beside the file
  # makes its directory a workspace without git. The save run, against
  # `stores-config`, bumps a store kept across a restart and one that is
  # not, runs `:!true` into the project's history, starts the job `hold`,
  # which a person waits on, and aborts with it running (`stores-expected`);
  # the restore run shows the workspace table with the history, then, once
  # config installs, `kept` back and `unkept` at its initial value, and the
  # summary and `*restore*` naming the stopped job
  # (`stores-restore-expected`).
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && f=../tests/headless/restore && mkdir "$dir/work" && cp $f/note.txt "$dir/work/note.txt" && touch "$dir/work/.project" && sed "s|@FILE@|$dir/work/note.txt|" $f/stores-script > "$dir/stores" && status=0 && { out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean $f/stores-config "$dir/stores") || status=$?; } && test "$status" -eq 134 && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | grep -v '^job \|^commands:' | diff $f/stores-expected - && out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean $f/stores-config $f/stores-restore-script) && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | grep -v '^job \|^commands:' | diff $f/stores-restore-expected -
  )
}

# tests/headless/restart/script
case_restart() {
  # Restart (tests/headless/restart; docs/dev-practices/the-gate.md, the
  # restart entries; lean/Editor/Restore/Restart.lean). Each runs in a
  # temporary directory with `--state` there; the output has that
  # directory written `@DIR@` and the editor's path `@EDITOR@`, and its job
  # lines and command list dropped. One script serves both processes: the
  # first runs it to `restarted`, the second, started with `--resume 1`,
  # from the line after. Through the launcher (`target/release/leanmacs`,
  # built by the `launcher` task, with `--default` the editor): `:restart`
  # probes the running editor, writes the session and the hand-over record
  # and execs the launcher, which starts the editor again with the session
  # handed over; what both print must be exactly `restart-expected` (the
  # buffer with its unsaved text, the split and the hidden tab, and the
  # summary that the window was closed and reopened), and then no record is
  # left, the first run's index is gone, the second's there, and only its
  # journals.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && dir=$(cd "$dir" && pwd -P) && f=../tests/headless/restart && editor=$(cd ../packages/.lake/build/bin && pwd -P)/editor && cp $f/note.txt "$dir/note.txt" && sed "s|@FILE@|$dir/note.txt|" $f/script > "$dir/script" && out=$(../target/release/leanmacs --data "$dir/data" --default ../packages/.lake/build/bin/editor -- headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/script") && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g; s|$editor|@EDITOR@|g" | grep -v '^job \|^commands:' | diff $f/restart-expected - && test ! -e "$dir/state/session/handover" && test ! -e "$dir/state/session/session-1.json" && test -e "$dir/state/session/session-2.json" && test -z "$(ls "$dir/state/session/journals" | grep -v '^2-')"
  )
  # The same with no launcher (decision 8): the editor run directly execs
  # itself, with no watcher and no fallback, and says so
  # (`restart-direct-expected`); the same files are left.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && dir=$(cd "$dir" && pwd -P) && f=../tests/headless/restart && editor=$(cd ../packages/.lake/build/bin && pwd -P)/editor && cp $f/note.txt "$dir/note.txt" && sed "s|@FILE@|$dir/note.txt|" $f/script > "$dir/script" && out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/script") && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g; s|$editor|@EDITOR@|g" | grep -v '^job \|^commands:' | diff $f/restart-direct-expected - && test ! -e "$dir/state/session/handover" && test ! -e "$dir/state/session/session-1.json" && test -e "$dir/state/session/session-2.json" && test -z "$(ls "$dir/state/session/journals" | grep -v '^2-')"
  )
}

# tests/headless/restart/probe-script
case_restart_probe() {
  # A probe that fails: `:restart` into a program that exits 3 whatever it
  # is given is refused, said, and the script goes on in the same process
  # with the session as it was (`probe-expected`); no record is written.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && dir=$(cd "$dir" && pwd -P) && f=../tests/headless/restart && editor=$(cd ../packages/.lake/build/bin && pwd -P)/editor && cp $f/note.txt "$dir/note.txt" && printf '#!/bin/sh\nexit 3\n' > "$dir/noprobe" && chmod +x "$dir/noprobe" && sed "s|@FILE@|$dir/note.txt|; s|@NOPROBE@|$dir/noprobe|" $f/probe-script > "$dir/script" && out=$(../packages/.lake/build/bin/editor headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/script") && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g; s|$editor|@EDITOR@|g" | grep -v '^job \|^commands:' | diff $f/probe-expected - && test ! -e "$dir/state/session/handover"
  )
}

# tests/headless/restart/fallback-script
case_restart_fallback() {
  # The fallback: `:restart` into a program that passes the probe and
  # otherwise exits 3 before restoring anything. The launcher's watcher sees
  # it end with the record still there, marks it failed, and the launcher it
  # execs starts the previous executable, the editor, which restores the
  # session and names it (`fallback-expected`); the watcher says so on
  # standard error, and no record is left. The first process's status is the
  # failed program's, so it is not asked for.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && dir=$(cd "$dir" && pwd -P) && f=../tests/headless/restart && editor=$(cd ../packages/.lake/build/bin && pwd -P)/editor && cp $f/note.txt "$dir/note.txt" && ending='exit 3' && printf '#!/bin/sh\n[ "$1" = --probe ] && { echo "probe: ok"; exit 0; }\n%s\n' "$ending" > "$dir/bad" && chmod +x "$dir/bad" && sed "s|@FILE@|$dir/note.txt|; s|@BAD@|$dir/bad|" $f/fallback-script > "$dir/script" && status=0 && { out=$(../target/release/leanmacs --data "$dir/data" --default ../packages/.lake/build/bin/editor -- headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/script" 2>"$dir/err") || status=$?; } && test "$status" -eq 3 && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g; s|$editor|@EDITOR@|g" | grep -v '^job \|^commands:' | diff $f/fallback-expected - && grep -qxF "leanmacs: $dir/bad ended before it restored the session; starting $editor" "$dir/err" && test ! -e "$dir/state/session/handover"
  )
  # The same with a program that sends itself SIGKILL (`killed-expected`).
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && dir=$(cd "$dir" && pwd -P) && f=../tests/headless/restart && editor=$(cd ../packages/.lake/build/bin && pwd -P)/editor && cp $f/note.txt "$dir/note.txt" && ending='kill -KILL $$' && printf '#!/bin/sh\n[ "$1" = --probe ] && { echo "probe: ok"; exit 0; }\n%s\n' "$ending" > "$dir/bad" && chmod +x "$dir/bad" && sed "s|@FILE@|$dir/note.txt|; s|@BAD@|$dir/bad|" $f/fallback-script > "$dir/script" && status=0 && { out=$(../target/release/leanmacs --data "$dir/data" --default ../packages/.lake/build/bin/editor -- headless --state "$dir/state" "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/script" 2>"$dir/err") || status=$?; } && test "$status" -eq 137 && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g; s|$editor|@EDITOR@|g" | grep -v '^job \|^commands:' | diff $f/killed-expected - && grep -qxF "leanmacs: $dir/bad ended before it restored the session; starting $editor" "$dir/err" && test ! -e "$dir/state/session/handover"
  )
}

# tests/headless/open-file/script
case_open_file() {
  # `open-file`'s prompt over real files, as a process, with no config
  # (tests/headless/open-file): the file source lists the directory typed so
  # far through the library's file service, directories first with
  # `directory` beside them and `.hidden` left out until a `.` is typed, from
  # the one read; `no` lists `notes/` with its match; `<Tab>` goes into it
  # and lists `todo.md`; `C-n` and `<Enter>` open it; and a directory that
  # is not there says why in the echo area and lists nothing. This entry is
  # one shell, as the session's is: it makes a temporary directory and
  # removes it by a trap, copies `open-file/tree` there, and writes the
  # script there from the template `open-file/script` with the directory's
  # absolute path in place of `@DIR@`. The editor must exit with status 0,
  # and its output, with that path written `@DIR@`, must be exactly
  # `open-file/expected`. Every job is waited for with `join`, so its lines
  # are fixed. No file is written. The prompt's view prints the cursor's
  # byte offset over the absolute path typed, which the scrub cannot
  # rewrite, so the directory is made from a template under `/tmp`, not
  # under `$TMPDIR`: its path is always 23 bytes, on every machine.
  (
    set -e
    dir=$(mktemp -d /tmp/open-file.XXXXXXXX) && trap 'rm -rf "$dir"' EXIT && cp -R ../tests/headless/open-file/tree "$dir/tree" && sed "s|@DIR@|$dir|g" ../tests/headless/open-file/script > "$dir/script" && out=$(../packages/.lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/script") && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | diff ../tests/headless/open-file/expected -
  )
}

# tests/headless/milestone/script
case_milestone() {
  # Milestone 1 over the whole program, with no config
  # (tests/headless/milestone): the headless mode with `--render`, whose
  # display is the real binding over the library's layout in cells of 8 by
  # 16, bound to the library's headless render session, which draws every
  # frame on the CPU renderer. The script opens a source file of 60 lines
  # with `:e`, runs an evil session on it (`2dw`, `.`, `u`, `j`, `cw` with a
  # committed text, `<Escape>`, `$ p`, `u`, `C-r`), scrolls with `C-f`,
  # saves with `:w`, and checks twice with `agree` that the last rows query
  # about the view gave the rows of the frame drawn of it; then `idle 1000`
  # waits for the render loop to be at rest and counts what it draws and is
  # handed over one second, which must be nothing. That second is the one
  # real-time wait of the gate's checks of the render loop
  # (docs/design/text-and-display.md). This entry is one shell, as the five
  # above are: it makes a temporary directory and removes it by a trap,
  # copies `milestone/source.txt` there, and writes the script there from
  # the template `milestone/script` with the copy's absolute path in place
  # of `@FILE@`. The editor must exit with status 0, its output, with the
  # temporary directory's path written `@DIR@`, must be exactly
  # `milestone/expected`, and the copy must hold the bytes of
  # `milestone/source-expected`.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && cp ../tests/headless/milestone/source.txt "$dir/source.txt" && sed "s|@FILE@|$dir/source.txt|" ../tests/headless/milestone/script > "$dir/script" && out=$(../packages/.lake/build/bin/editor headless --render "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/script") && printf '%s\n' "$out" | sed "s|$dir|@DIR@|g" | diff ../tests/headless/milestone/expected - && cmp "$dir/source.txt" ../tests/headless/milestone/source-expected
  )
}

# window-host
case_window_host() {
  # The window mode's wiring, `editor <file>` (lean/Editor/Window/Real.lean),
  # on the library's scripted platform, as a process of its own, so that its
  # render session is the only one the process starts: a cells display bound
  # to the presenter, the host opening a copy of `ex/note.txt`, the scripted
  # sample window opening, sending its fixed input and asking to close. The
  # scenario must exit 0, which it does only once the window has run and
  # closed and the render session's counters show a frame drawn, and the
  # copy must be unchanged. It opens no window and touches no clipboard of
  # the desktop's.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && cp ../tests/headless/ex/note.txt "$dir/note.txt" && .lake/build/bin/ffi-test window-host "$dir/note.txt" && cmp "$dir/note.txt" ../tests/headless/ex/note.txt
  )
  # The same wiring with no file, as Finder starts the app: the host posts
  # no open, and the window runs on the editor's one empty buffer. It must
  # exit 0 as the scenario with a file does. It touches no file.
  (
    set -e
    .lake/build/bin/ffi-test window-host
  )
}

# window-host-config
case_window_host_config() {
  # The same wiring with no file and config loaded at start, on the fixture
  # tests/window/title-bar/config, whose `setup` keeps the standard title
  # bar: the host waits for the start-up reload, with no bound so that the
  # result does not race the clock (this task's time limit ends a run that
  # hangs), and the scripted window must be opened with the standard title
  # bar. The toolchain's directory and the `.olean` directory are passed in,
  # as for config-test. It touches no file.
  (
    set -e
    .lake/build/bin/ffi-test window-host-config "$(lean --print-prefix)" .lake/build/lib/lean ../tests/window/title-bar/config
  )
}

# window-host-restart
case_window_host_restart() {
  # The same wiring ending in a restart (lean/FfiTest/Editor/Window/Real.lean,
  # `windowHostRestartScenario`): config loaded at start from the same
  # fixture, a state directory and a launcher in a temporary directory, and
  # `restart` run once the restore has finished, into a probe script that
  # prints `probe: ok`. The host is handed a recording exec that fails: the
  # host must call it once, with `<launcher> --handover <record>`, only once
  # the shutdown has run and the window has closed, then say the failed exec
  # and end with status 1, the record on disk the plan's. Nothing is exec'd.
  # It writes only in its temporary directory.
  (
    set -e
    .lake/build/bin/ffi-test window-host-restart "$(lean --print-prefix)" .lake/build/lib/lean ../tests/window/title-bar/config
  )
}

# window-host-base
case_window_host_base() {
  # The same wiring handed a config base that is not `Editor` alone, as the
  # editor's `main` hands the window mode its package set's (`Editor`, then
  # the entry module of each package of the set; lean/Editor/Main.lean,
  # "The base"): here `Editor` and `ConfigFixture`, a module linked into
  # ffi-test that `Editor` does not import. The fixture
  # tests/window/base/config names a declaration of that module and keeps
  # the standard title bar, so the scripted window is opened with it only
  # if the window mode handed the elaborator the base it was handed: on
  # `Editor` alone the start-up reload is rejected with an unknown
  # identifier. The headless mode's handing on of the set's base is the
  # package fixtures' (`package-names` of shipped-themes, `config` of
  # compile); this is the window mode's.
  (
    set -e
    .lake/build/bin/ffi-test window-host-base "$(lean --print-prefix)" .lake/build/lib/lean ../tests/window/base/config
  )
}

# window-host-generate
case_window_host_generate() {
  # The same wiring handed a generator, as the editor's `main` hands it one,
  # on a temporary copy of tests/window/title-bar/config, which holds a root
  # and neither generated file: the start-up reload must create the
  # directory's `lean-toolchain` and `lakefile.toml` and load the config, so
  # the window mode hands the session the generator it was handed. It
  # writes in the temporary directory alone, which a trap removes.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && cp -R ../tests/window/title-bar/config "$dir/config" && .lake/build/bin/ffi-test window-host-generate "$(lean --print-prefix)" .lake/build/lib/lean "$dir/config"
  )
}

# window-host-direct
case_window_host_direct() {
  # The same wiring as the editor starts it when run directly, with
  # `--sysroot` and no `--oleans`: the command line is read for the default
  # set's editor, so the `.olean` directory is the one that executable
  # finds by default, which the package-set build records beside it
  # (packages/.lake/build/bin/editor.oleans; lean/Editor/ModuleLookup.lean).
  # The same config must load, so that directory holds the modules config
  # is elaborated on. Then the same for the fixture set's editor.
  (
    set -e
    .lake/build/bin/ffi-test window-host-direct ../packages/.lake/build/bin/editor "$(lean --print-prefix)" ../tests/window/title-bar/config
  )
  (
    set -e
    .lake/build/bin/ffi-test window-host-direct ../tests/packages/.lake/build/bin/editor "$(lean --print-prefix)" ../tests/window/title-bar/config
  )
}

# window-host-undrawn
case_window_host_undrawn() {
  # The same wiring on the library's scripted platform whose renderer cannot
  # be made, as a machine with no usable GPU gives: the window runs with
  # nothing drawing in it. The scenario must exit 0, which it does only when
  # the window mode ended with status 1 and no render session was started;
  # stderr must hold the window mode's line saying why nothing drew, with
  # the platform's reason whole (`SCRIPTED_NO_RENDERER` in
  # crates/editor-ffi/src/window.rs); and the copy must be unchanged.
  (
    set -e
    dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT && cp ../tests/headless/ex/note.txt "$dir/note.txt" && err=$(.lake/build/bin/ffi-test window-host-undrawn "$dir/note.txt" 2>&1 >/dev/null) && printf '%s\n' "$err" | grep -qxF "editor: nothing could draw in the window: the scripted platform's window has no renderer: pas de GPU" && cmp "$dir/note.txt" ../tests/headless/ex/note.txt
  )
}

# tests/packages/greeting/tests/headless/hello/script: prepared by
# prepare_greeting, which installs the fixture set into the prepared
# directory, and run here.
case_greeting() {
  # A set's editor installed into a directory of its own (the facet
  # `editorInstall`): the fixture set's, into a fresh temporary directory,
  # runs the fixture package `greeting`'s headless fixture with no `.olean`
  # directory given, so every module it loads is found through the
  # install's relative record (`lib/lean`) under the install's own
  # directory; on macOS the copy's ad-hoc signature verifies; and a second
  # install into the same directory is refused, saying it exists. The set's
  # editor is up to date after `lean`, so this builds nothing; it writes
  # only the temporary directory and the records beside the set's editor,
  # which hold the same text, and it runs Cargo's own up-to-date check
  # under target/, as `:editorRust` above does. LEAN_CC is set as `lean`
  # sets it, so the link's environment record is unchanged.
  (
    set -e
    f=../tests/packages/greeting/tests/headless/hello && out=$("$prepared/greeting/v/editor" headless "$(lean --print-prefix)" '' $f/config $f/script) && printf '%s\n' "$out" | diff $f/expected - || { printf '%s\n' "$out"; echo 'ffi-test: the install of the fixture set did not run its fixture'; exit 1; }
  )
  # And the editor of the default set, which does not hold the fixture
  # package, has no such command: on the same config and script its
  # headless mode must print `run greeting-hello: no such command`. So the
  # command above came from the set, not from the core.
  (
    set -e
    out=$(../packages/.lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/packages/greeting/tests/headless/hello/config ../tests/packages/greeting/tests/headless/hello/script) && printf '%s\n' "$out" | grep -qxF 'run greeting-hello: no such command'
  )
}

# The greeting entry's build: a set's editor installed into a directory of
# its own, the one `run` then runs; a second install into it is refused.
prepare_greeting() {
  mkdir -p "$prepared/greeting"
  (
    set -e
    f=../tests/packages/greeting/tests/headless/hello && EDITOR_INSTALL_DIR="$prepared/greeting/v" LEAN_CC=/usr/bin/cc lake -d ../tests/packages build --wfail -q :editorInstall && test "$(cat "$prepared/greeting/v/editor.oleans")" = lib/lean && { test "$(uname)" != Darwin || codesign --verify --strict "$prepared/greeting/v/editor"; } && status=0 && { out=$(EDITOR_INSTALL_DIR="$prepared/greeting/v" LEAN_CC=/usr/bin/cc lake -d ../tests/packages build -q :editorInstall 2>&1) || status=$?; } && test "$status" -ne 0 && printf '%s\n' "$out" | grep -qF "$prepared/greeting/v already exists" || { printf '%s\n' "$out"; echo 'ffi-test: the install of the fixture set did not install, or took a directory that exists'; exit 1; }
  )
}

tab=$(printf '\t')

[ "$#" -ge 1 ] || usage
command=$1
shift
case $command in
  prepare)
    [ "$#" -eq 1 ] || usage
    prepared=$1
    mkdir -p "$prepared"
    prepared=$(cd "$prepared" && pwd -P)
    prepare_greeting
    echo "wiring-runs: prepared $prepared"
    ;;
  run)
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
    prepared=$(cd "$1" && pwd -P)
    group=${2:-}
    case $group in '' | fixtures | scenarios) ;; *) usage ;; esac
    failures=
    while IFS=$tab read -r case_group name <&3; do
      [ -z "$group" ] || [ "$group" = "$case_group" ] || continue
      echo "wiring-runs: $name"
      # The case runs as a command of its own, in a subshell with errexit,
      # and its status is read after it: never as the condition of an `if`
      # or an operand of `||` or `&&`, where sh ignores errexit in all the
      # case runs, its steps' own `set -e` too, so that only its last
      # step's status would count.
      set +e
      (
        set -e
        "case_$name"
      )
      status=$?
      set -e
      if [ "$status" -ne 0 ]; then
        echo "wiring-runs: FAILED: $name" >&2
        failures="$failures $name"
      fi
    done 3<<CASES
$(table)
CASES
    if [ -n "$failures" ]; then
      echo "wiring-runs: failed:$failures" >&2
      exit 1
    fi
    ;;
  *) usage ;;
esac
