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
| `key <logical> <physical> <modifiers>` | Sends a press of a key, with no text, as the window would report it: through the library's window input, in order with what was asked before. `<logical>` is one character (`a`) or a named key in angle brackets (`<Escape>`, a W3C UI Events `key` name); `<physical>` is a W3C UI Events `code` (`KeyA`) or `-`; `<modifiers>` is `shift`, `control`, `alt` and `super` joined with `+`, or `-`. The editor prints `key arrived:` with the three. The editor loop drops the key: key lookup comes later. |
| `commit <text>` | Sends the rest of the line, trimmed, as an input method's composition would end with it, the same way as `key`. The editor loop inserts it at the focused window's cursors. A `commit` with no text is refused. |
| `scene` | Prints the last scene the editor loop published: the frame, then each view and the text its snapshot holds. |

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

A third script, `tests/headless/scene-script`, commits text and asks for
the scene, then reloads and runs a job; its output must be exactly
`tests/headless/scene-expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/scene-script
scene 0x0, focused 0, echo "", preedit -, published 1
view 0 0,0 0x0: "hello", scroll 0, selections 5..5
reload 1: installed, 2 chunks, 1 commands
spawn count: job 1
job 1 count: ok
scene 0x0, focused 0, echo "", preedit -, published 8
view 0 0,0 0x0: "hello", scroll 0, selections 5..5
```

The editor runs its command loop. The loop has no frame until the first
event from the window input arrives (a `key` or a `commit`): it then makes
one, 0 by 0, with one window on a buffer called `scratch` of an empty text.
So a script that sends no window event has no frame, and the texts its
commands make keep the indices `show` prints. Once there is a frame, every
event the editor handles is followed by a scene, published to a recorder
that stands in for the window's display: a window event, a request, a
reload that installs, a job's command. `published` counts them, so the
second `scene` above, seven events after the first, shows that the reload
and the job were each followed by one. A window's close request ends the
loop.

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
scene <w>x<h>, focused <id or ->, echo <quoted>, preedit <quoted or ->, published <n>
view <id> <x>,<y> <w>x<h>: <quoted text>, scroll <offset>, selections <anchor>..<head> …
scene: none
loop: refused: <error>
```

`scene` prints the frame's size, the focused view (`-` while the frame does
not have the keyboard focus), the echo area, the input method's preedit
(`-` when there is none) and how many scenes have been published; then, for
each view in drawing order, its rectangle, the text of its snapshot, read
from the library, and the offsets of its scroll anchor and of each range of
its selection. `scene: none` means no scene has been published: no window
event has arrived.

What the editor loop is refused is in the scene's echo area, as
`refused: <error>`: a commit the library refused, and a text or a snapshot
that was gone when the scene was made. A view whose buffer's text was
released, by a command, is left out of the scene, so the scene line is then
followed by fewer view lines, or none. `loop: refused: <error>` is for a
program of the loop that was itself refused. None is today; the line is
there so that one would not be dropped in silence.

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
