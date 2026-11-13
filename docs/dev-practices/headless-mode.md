# The headless mode

```sh
editor headless <sysroot> <olean dir> <config dir> <script file>
```

This is the editor with no window. It loads the config in a directory, runs
a script against it and prints what happened. Every path is an argument:
`<sysroot>` is the Lean toolchain's directory (`lean --print-prefix`) and
`<olean dir>` the directory of the editor package's `.olean` files
(`lean/.lake/build/lib/lean`). Nothing is read from the environment or the
working directory.

A config is the `.lean` files directly in the config directory, elaborated in
the byte order of their names, each on top of the one before. They have no
`import` line: `Editor` is imported and opened for them. Config defines
commands and jobs, and a `setup` that registers them:

```lean
def greet : EditorM Unit := do
  let text ← createText "hello"
  append text ", world"

def count : Unit → JobM Nat := fun _ => do
  sleep 1
  return 42

def setup : SetupM Unit := do
  command "greet" greet
  job "count" count fun n => discard <| createText s!"counted {n}"
```

A command (`EditorM`) may change editor state and cannot wait. A job
(`JobM`) may wait, here for a millisecond, and cannot change editor state:
it runs in the background, and its result goes to the handler it was
registered with, which makes a command the editor runs. A job is not a
command, and a reload's report does not count it as one.

A job can also load a file and save one, which a command cannot: it waits
for the library to do it. `File.load` takes an absolute path and the longest
file to load, in bytes, and answers the file's text, as a snapshot the job
holds, or why it was refused; the refusal is a value the job matches on.
The job's handler takes what was loaded into the editor's texts:

```lean
def openNote : Unit → JobM JobSnapshotId := fun _ => do
  match ← File.load "/home/me/note.txt" 1000000 with
  | .ok file => return file.snapshot
  | .error error => throw error.describe

def setup : SetupM Unit := do
  job "open" openNote fun loaded => discard loaded.toText
```

`File.save` writes a snapshot as a file, by a temporary file beside it and
a rename, and is told what to expect on disk: the stamp a load or the last
save answered, no file, or whatever is there. A save that finds another
file than it expects is refused, with what is there, and writes nothing.

A `setup` registers each command name and each job name once. One that
registers a name twice is rejected, like a chunk that does not elaborate.

A script is one directive a line. Blank lines and lines that start with `#`
are skipped.

| Directive | Does |
|---|---|
| `reload` | Asks for the config to be reloaded. Elaboration runs in the background, and the editor goes on answering. |
| `settle` | Waits, for up to 30 seconds, until everything asked so far has been handled and no reload is running. |
| `run <name>` | Runs the command registered under that name. |
| `spawn <name>` | Starts the job registered under that name. It runs in the background, and the editor goes on answering. |
| `join` | Waits, for up to 30 seconds, until everything asked so far has been handled and no job is running. |
| `show` | Prints the commands, the texts and the stores. |
| `key <logical> <physical> <modifiers>` | Sends a press of a key, with no text, as the window would report it: through the library's window input, in order with what was asked before. `<logical>` is one character (`a`) or a named key in angle brackets (`<Escape>`, a W3C UI Events `key` name); `<physical>` is a W3C UI Events `code` (`KeyA`) or `-`; `<modifiers>` is `shift`, `control`, `alt` and `super` joined with `+`, or `-`. The editor prints `key arrived:` with the three. |

With the fixture the gate uses (`tests/headless`):

```console
$ cd lean
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/script
reload 1: installed, 2 chunks, 1 commands
run greet: ok
run missing: no such command
commands: greet
text 0: "hello, world"
spawn count: job 1
job 1 count: ok
commands: greet
text 0: "hello, world"
text 1: "counted 42"
```

The gate runs a second script on the same config, `tests/headless/keys-script`,
whose output must be exactly `tests/headless/keys-expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/keys-script
key arrived: a KeyA shift+control
key arrived: <Escape> Escape -
```

The lines it can print:

```
reload <n>: installed, <c> chunks, <k> commands
reload <n>: rejected
diagnostic: <source>:<line>:<column>: <severity>: <first line of the message>
run <name>: ok            (or "refused: <error>", or "no such command")
spawn <name>: job <id>    (or "no such job")
job <id> <name>: ok       (or "refused: <error>", "failed: <message>", "cancelled")
event <source id> <code>
key arrived: <logical> <physical> <modifiers>
commands: <names>
text <index>: <quoted text>
store <name> v<version>: <value>
```

A job's line is printed when the editor has dealt with its result: `ok` when
the handler's command ran, `refused` when the library refused that command,
`failed` when the job threw, and `cancelled` when a reload that installed
replaced the config that registered it. A job the script leaves running is
cancelled when the script ends.

A reload that is rejected (a chunk does not elaborate, or `setup` throws)
prints its diagnostics and leaves the config that was loaded in place, with
its jobs still running. The exit status is 0 when the script ran to its end,
1 when it could not, and 2 for a command line it does not understand. With
status 1 a line on stderr says why: the script cannot be read; a `settle`,
named by its line, ran out with a reload still running (a chunk or `setup`
is slow or does not end); a `join`, named by its line, ran out with a job
still running; or the editor thread did not answer.
