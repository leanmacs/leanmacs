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

A command can start a job, by the name it is registered under, and hand it
arguments; a job that takes them is registered with `jobWith`. The command
does not wait: the job's result comes back later, as the command its
handler makes, here one that says the result in the echo area:

```lean
def double : List Argument → JobM Nat := fun arguments => do
  let [.nat n] := arguments | throw "double takes one number"
  sleep 1
  return 2 * n

def setup : SetupM Unit := do
  jobWith "double" double fun n => message s!"doubled to {n}"
  command "ask" (discard <| startJob "double" [.nat 21])
```

What else a command is written with (buffers, windows, selections, undo,
modes, messages) is the editor API, `lean/Editor/Api.lean`
(`docs/design/lean-runtime.md`, "The editor API").

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

The editor ships two commands over those, compiled in, so they are there
with no config and `show` lists them before config's
(`lean/Editor/Files.lean`):

| Command | Does |
|---|---|
| `open-file` | Opens the file at the path that is its first argument in the window it is called with: it starts the job `load-file`, and when the file is loaded a buffer of its text, called by its base name, is shown there. A path a buffer already holds is shown at once. A file that is not there, or is refused for another reason, is said in the echo area, `cannot open <path>: <why>`, and the window shows what it showed. With no path it asks for one, with the prompt `Open file: `, and opens the answer. |
| `save-buffer` | Saves the buffer of the window it is called with to its file: it starts the job `save-file`, and when the file is written the echo area says `wrote <path>` and the buffer is no longer modified. A file that changed on disk since it was loaded is left as it is, and the echo area says `cannot save <path>: <why>`. With `true` as its first argument it writes whatever is on disk. |

`run <name>` hands a command no argument, so a script cannot give
`open-file` its path that way. Config's own command calls the operation
the command is written with, `Files.open view path`, as the fifth fixture
below does; `Files.save buffer` is the save. Or the script runs
`open-file` with no path, commits the path into the minibuffer and accepts,
as the sixth fixture does. While a load or a save is in flight the editor
goes on answering: what is typed meanwhile is handled first.

The editor ships two more commands, compiled in, and one mode
(`lean/Editor/Minibuffer.lean`). A command asks for a string with
`prompt label continuation initial`, which opens the minibuffer and
returns at once; `continuation` names the command that receives the
answer, as its first argument.

| Command | Does |
|---|---|
| `minibuffer-accept` | Accepts the open prompt with the minibuffer's text as the answer: the prompt is closed, the focus goes back to the window it was asked from, and the command the prompt named runs with the answer. With no prompt open it says so in the echo area. |
| `minibuffer-cancel` | Cancels the open prompt: it is closed, the focus goes back, and the command it named does not run. With no prompt open it says so. |

The mode `minibuffer` is the major mode of the minibuffer's buffer. It
puts the two commands on the keys the input scheme has for the roles
`activate` and `quit`; under the Vim scheme, where typing in the minibuffer
is text, they are on `<Enter>` and `<Escape>`.

And it ships evil, compiled in (`lean/Editor/Evil.lean`): the commands the
Vim scheme's keys run, so the editor moves and inserts with no config.

| Command | Keys | Does |
|---|---|---|
| `move` | `h j k l w b e W B E 0 ^ $ g g G`, each after a count | Moves the cursor by the motion the key names, as Vim does; in a visual state it moves the selection's head. |
| `insert`, `append`, `insert-line-start`, `append-line-end` | `i`, `a`, `I`, `A` | Run by its key, begins an insert: before the cursor, after it, at the line's first character that is not a blank, at the line's end. Run by its name it begins none (below). |
| `self-insert` | A key that prints, in insert state and in the minibuffer | Inserts what the key prints at the cursor. Everything typed until `<Escape>` is one step of the history. |
| `normal` | `<Escape>` | Run by its key, returns to normal state. From insert state the cursor steps back one character. Run by its name it leaves the view in the state it is in (below). |
| `visual`, `visual-line` | `v`, `V` | Run by its key, enters a visual state: a motion then extends the selection, by characters or by whole lines. Run by its name it enters none (below). |

**A Vim state is entered by a key, not by a command.** The Vim scheme
enters the state when a key bound to it completes, and the command that
key runs then gives the selection the shape of the state the view is now
in. So `normal`, `visual`, `visual-line`, `insert`, `append`,
`insert-line-start` and `append-line-end` enter a state only when a key
that enters it runs them:

- `run <name>` of one of the seven prints `run <name>: ok` and enters no
  state: the view's status line names the state it was in, the next key
  is looked up in that state's keymaps, and the echo area says nothing.
  In normal state `run insert` leaves the cursor where it is, and a
  `commit` after it is still dropped.
- The command still reshapes the selection, for the state the view is
  in. In normal state `run append` moves the cursor one character on,
  `run append-line-end` to the line's last character and
  `run insert-line-start` to its first character that is not a blank,
  which is where each insert would begin, rested as normal state rests a
  cursor.
- A key that config binds to one of these names (`bindKey "C-c i"
  "insert"`) enters no state either: a binding to a command's name runs
  the command and leaves the scheme's state as it was.
- A script enters a state with `key`: `key i KeyI -`, `key <Escape>
  Escape -`, `key v KeyV -`.

Why the command cannot do it, or say that it did not, is in
`docs/design/keymaps-and-modes.md`, "What a scheme reports of a view".

The other default keys of the Vim scheme (the operators `d c y`, `x p P`,
`o O`, `u`, `C-r`, `.`, `:`) name commands that are not built: such a key
says `<name>: no such command` in the echo area.

A `setup` registers each command name and each job name once. One that
registers a name twice is rejected, like a chunk that does not elaborate.

`setup` also binds key sequences to command names, written as key strings
(`C-c s`, `<Escape>`; the table in `docs/design/keymaps-and-modes.md`, "Key
strings"):

```lean
def setup : SetupM Unit := do
  command "greet" greet
  bindKey "C-c g" "greet"
```

A key string that is not keys, or names none, is refused, and so is a
`setup` that binds one sequence twice. A binding to a name nothing
registers is accepted, and says `<name>: no such command` when the key
runs. A reload replaces config's bindings with the new config's; one that
is rejected keeps them.

A script is one directive a line. Blank lines and lines that start with `#`
are skipped.

| Directive | Does |
|---|---|
| `reload` | Asks for the config to be reloaded. Elaboration runs in the background, and the editor goes on answering. |
| `settle` | Waits, for up to 30 seconds, until everything asked so far has been handled and no reload is running. |
| `run <name>` | Runs the command registered under that name, through the editor loop, as a key would: with the focused window, guarded against the interrupt key, and rolled back if it does not run to its end. It is no key, so the input scheme's state is as it was: a command that a key enters a Vim state with enters none (the table of evil's commands, above). |
| `spawn <name>` | Starts the job registered under that name. It runs in the background, and the editor goes on answering. |
| `join` | Waits, for up to 30 seconds, until everything asked so far has been handled and no job is running. |
| `show` | Prints the commands, the texts and the stores. |
| `key <logical> <physical> <modifiers>` | Sends a press of a key, with no text, as the window would report it: through the library's window input, in order with what was asked before. `<logical>` is one character (`a`) or a named key in angle brackets (`<Escape>`, a W3C UI Events `key` name); `<physical>` is a W3C UI Events `code` (`KeyA`) or `-`; `<modifiers>` is `shift`, `control`, `alt` and `super` joined with `+`, or `-`. The editor prints `key arrived:` with the three. The editor loop steps the key through its input scheme, and runs the command a completed sequence is bound to. |
| `commit <text>` | Sends the rest of the line, trimmed, as an input method's composition would end with it, the same way as `key`. The editor loop inserts it at the focused window's cursors where the view takes typed text: under the Vim scheme, in insert state and in the minibuffer. In normal state it is dropped. A `commit` with no text is refused. |
| `scene` | Prints the last scene the editor loop published: the frame, then each view and the text its snapshot holds, and after each view its status line: the name of the view's Vim state, its buffer's name, and a modified field while the buffer is modified. While a prompt is open the minibuffer's view is printed after the windows', with the prompt text as its status line. |

With the fixture the gate uses (`tests/headless`):

```console
$ cd lean
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/script
reload 1: installed, 2 chunks, 1 commands
run greet: ok
run missing: no such command
commands: open-file save-buffer minibuffer-accept minibuffer-cancel move normal visual visual-line insert append insert-line-start append-line-end self-insert greet
text 0: ""
text 1: "hello, world"
spawn count: job 1
job 1 count: ok
commands: open-file save-buffer minibuffer-accept minibuffer-cancel move normal visual visual-line insert append insert-line-start append-line-end self-insert greet
text 0: ""
text 1: "hello, world"
text 2: "counted 42"
```

Text 0 is the scratch buffer's: the editor loop makes its frame, and that
buffer, for the first command it runs. `open-file`, `save-buffer`,
`minibuffer-accept`, `minibuffer-cancel` and evil's nine, from `move` to
`self-insert`, are the commands the editor ships, compiled in: `show`
lists them before config's.

The gate runs a second script on the same config, `tests/headless/keys-script`,
whose output must be exactly `tests/headless/keys-expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/keys-script
key arrived: a KeyA shift+control
key arrived: <Escape> Escape -
```

A third script, `tests/headless/scene-script`, presses `i`, commits text
and asks for the scene, then reloads and runs a job; its output must be
exactly `tests/headless/scene-expected`. A committed text is typed text, so
it is inserted in insert state, which `i` enters; in normal state it would
be dropped:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/scene-script
key arrived: i KeyI -
scene 0x0, focused 0, echo "", preedit -, published 2
view 0 0,0 0x0: "hello", scroll 0, selections 5..5
status 0: status.state "insert", status.name "scratch", status.modified "[+]"
reload 1: installed, 2 chunks, 1 commands
spawn count: job 1
job 1 count: ok
scene 0x0, focused 0, echo "", preedit -, published 9
view 0 0,0 0x0: "hello", scroll 0, selections 5..5
status 0: status.state "insert", status.name "scratch", status.modified "[+]"
```

A fourth, `tests/headless/dispatch/script`, runs on a config of its own,
`tests/headless/dispatch/config`, which registers `spin`, a command that
inserts `spin` and then asks the text its revision a thousand million
times, and `mark`, which inserts `mark`, and binds `C-c s` and `C-c m` to
them. It sends `C-c s` and then `C-g`, the interrupt key, which stops
`spin` and rolls its insertion back, then `C-c m`, which runs to its end.
The config also registers the job `double` and the command `ask` shown
above, on `C-c d`: the script sends `C-c d`, waits for the job with `join`,
and asks for the scene, whose echo area holds what the job's command said.
Its output must be exactly `tests/headless/dispatch/expected`; were `spin`
not stopped, the gate's time limit would end the run:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/dispatch/config ../tests/headless/dispatch/script
reload 1: installed, 1 chunks, 3 commands
key arrived: c KeyC control
key arrived: s KeyS -
key arrived: g KeyG control
scene 0x0, focused 0, echo "spin: interrupted", preedit -, published 3
view 0 0,0 0x0: "", scroll 0, selections 0..0
status 0: status.state "normal", status.name "scratch"
key arrived: c KeyC control
key arrived: m KeyM -
scene 0x0, focused 0, echo "", preedit -, published 6
view 0 0,0 0x0: "mark", scroll 0, selections 4..4
status 0: status.state "normal", status.name "scratch", status.modified "[+]"
key arrived: c KeyC control
key arrived: d KeyD -
job 1 double: started
job 1 double: ok
scene 0x0, focused 0, echo "doubled to 42", preedit -, published 11
view 0 0,0 0x0: "mark", scroll 0, selections 4..4
status 0: status.state "normal", status.name "scratch", status.modified "[+]"
```

The status line after the first scene's view has the state's name and the
buffer's: `spin` was rolled back, so the buffer is not modified. After
`mark` it has the modified field too.

A fifth, `tests/headless/files/script`, runs the file commands the editor
ships, on the config in `tests/headless/files/config`, and touches no file.
`save-buffer` is compiled in, so it runs with no config registering it: on
the scratch buffer, which shows no file, it says so in the echo area. The
config registers `open-relative`, which calls `Files.open` on the focused
view with a path that is not absolute:

```lean
def openRelative : EditorM Unit := do
  Files.open (← editorState).frame.focused "notes/relative.txt"
```

That starts the compiled job `load-file`. The library refuses a path that
is not absolute before it asks the file system, the refusal comes back as
the job's result, and the job's command says it in the echo area. Its
output must be exactly `tests/headless/files/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/files/config ../tests/headless/files/script
reload 1: installed, 1 chunks, 1 commands
run save-buffer: ok
scene 0x0, focused 0, echo "scratch has no file to save to", preedit -, published 1
view 0 0,0 0x0: "", scroll 0, selections 0..0
status 0: status.state "normal", status.name "scratch"
run open-relative: ok
job 1 load-file: started
job 1 load-file: ok
scene 0x0, focused 0, echo "cannot open notes/relative.txt: the path is not absolute", preedit -, published 5
view 0 0,0 0x0: "", scroll 0, selections 0..0
status 0: status.state "normal", status.name "scratch"
```

A sixth, `tests/headless/prompt/script`, asks for a prompt and answers it,
on the config in `tests/headless/prompt/config`. A command cannot wait for
an answer, so it names the command that receives it and returns at once.
The config registers that command with `commandWith`, which gives it what
it was called with: the answer is its first argument.

```lean
def greetNamed (call : Call) : EditorM Unit :=
  match call.arguments with
  | .str name :: _ => message s!"hello {name}"
  | _ => message "hello"

def askName : EditorM Unit :=
  discard <| prompt "Name: " { command := "greet-named" } "Ada"

def setup : SetupM Unit := do
  commandWith "greet-named" greetNamed
  command "ask-name" askName
```

While the prompt is open the minibuffer is a view of its own, view 1, with
the focus, and under the Vim scheme it is in a state where typing is text:
a key that prints is inserted there, by the compiled command
`self-insert`, and so is a text `commit` sends. `scene` prints the input
typed so far as that view's text and the prompt text as its status line,
in the face `minibuffer.prompt`. The script types `!` with a key, after
the `Ada` the prompt was asked with. `<Enter>` accepts and `<Escape>`
cancels: the minibuffer's state binds those two keys to the compiled
commands `minibuffer-accept` and `minibuffer-cancel`. The command that
receives the answer prints no line of its own: what it said is in the echo
area. The last part runs the compiled `open-file` with no path: it asks
for one, and opens the answer, here a committed path that is not absolute,
which the library refuses before it asks the file system. Its output must
be exactly `tests/headless/prompt/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/prompt/config ../tests/headless/prompt/script
reload 1: installed, 1 chunks, 2 commands
run ask-name: ok
key arrived: ! Digit1 shift
scene 0x0, focused 1, echo "", preedit -, published 2
view 0 0,0 0x0: "", scroll 0, selections 0..0
status 0: status.state "normal", status.name "scratch"
view 1 0,0 0x0: "Ada!", scroll 0, selections 4..4
status 1: minibuffer.prompt "Name: "
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "hello Ada!", preedit -, published 5
view 0 0,0 0x0: "", scroll 0, selections 0..0
status 0: status.state "normal", status.name "scratch"
run ask-name: ok
key arrived: <Escape> Escape -
scene 0x0, focused 0, echo "", preedit -, published 8
view 0 0,0 0x0: "", scroll 0, selections 0..0
status 0: status.state "normal", status.name "scratch"
run open-file: ok
key arrived: <Enter> Enter -
job 1 load-file: started
job 1 load-file: ok
scene 0x0, focused 0, echo "cannot open notes/relative.txt: the path is not absolute", preedit -, published 15
view 0 0,0 0x0: "", scroll 0, selections 0..0
status 0: status.state "normal", status.name "scratch"
```

A seventh, `tests/headless/evil-script`, runs on the first fixture's config
directory and loads none of it: it has no `reload`. So every command its
keys run is one the editor ships. It presses `i`, which begins an insert,
then the five keys of `hello`, each typed text; `<Escape>`, which returns
to normal state with the cursor on the last character typed; and `0`,
which is a motion there. Its output must be exactly
`tests/headless/evil-expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/evil-script
key arrived: i KeyI -
key arrived: h KeyH -
key arrived: e KeyE -
key arrived: l KeyL -
key arrived: l KeyL -
key arrived: o KeyO -
scene 0x0, focused 0, echo "", preedit -, published 6
view 0 0,0 0x0: "hello", scroll 0, selections 5..5
status 0: status.state "insert", status.name "scratch", status.modified "[+]"
key arrived: <Escape> Escape -
scene 0x0, focused 0, echo "", preedit -, published 8
view 0 0,0 0x0: "hello", scroll 0, selections 4..4
status 0: status.state "normal", status.name "scratch", status.modified "[+]"
key arrived: 0 Digit0 -
scene 0x0, focused 0, echo "", preedit -, published 10
view 0 0,0 0x0: "hello", scroll 0, selections 0..0
status 0: status.state "normal", status.name "scratch", status.modified "[+]"
```

The status line's first field is the name of the view's Vim state, in the
face `status.state`: `insert` while the keys are typed text, and `normal`
before `i` and after `<Escape>`. In insert state the selection is a bar
between characters, after what was typed; in normal state it is on a
character. `scene` prints a selection's two ends and not its shape or the
cursor's.

The editor runs its command loop, under the Vim scheme. The loop has no
frame until it is first needed: for the first event from the window input
(a `key` or a `commit`), the first `run`, or the first job's command. It
then makes one, 0 by 0, with one window on a buffer called `scratch` of an
empty text, which is text 0 in what `show` prints. Every command goes
through the loop, whichever of the three ran it. Once there is a frame,
every event the editor handles is followed by one scene, published to a
recorder that stands in for the window's display: a window event, a
request, a reload that installs, a job's command. `published` counts them,
so the second `scene` of the third script, seven events after the first,
shows that the reload and the job were each followed by one. A window's
close request ends the loop.

A key press is stepped through the scheme. Config's bindings are looked up
first, then the scheme's own keymaps, which are those of the view's Vim
state. The motions, `i a I A`, `v V`, `<Escape>`, typed text and the
minibuffer's two keys run commands the editor ships; a default key whose
command is not built says `<name>: no such command` in the echo area. A
command a key runs prints nothing: what became of it is
in the next scene's echo area, `<name>: no such command`,
`<name>: refused: <error>` or `<name>: interrupted`, and a command that was
refused or interrupted is rolled back: its buffer's text and selections are
as they were before it. `C-g` is the interrupt key: it stops a command that
is running at its next request to the editor, and is then looked up like
any other key. A command that takes longer than 100 ms is logged on stderr,
`slow command: <name> took <n> ms`, and not on the output.

A command run by `run <name>` and a job's command are treated the same way,
and each also prints a line: how it ended. A job's command is named by its
job in the echo area, `job <id> <name>: refused: <error>`. It does not
clear the echo area as a key's command and a `run` do, so what it leaves
there is what it said itself (`message`), or what the last command left.
A job a command asks for is started once the command has run to its end,
and printed, `job <id> <name>: started`; a command that fails starts none.

The lines it can print:

```
reload <n>: installed, <c> chunks, <k> commands
reload <n>: rejected
diagnostic: <source>:<line>:<column>: <severity>: <first line of the message>
run <name>: ok            (or "refused: <error>", "interrupted",
                           "no such command", "no window", or "no frame"
                           when the loop's frame could not be made)
spawn <name>: job <id>    (or "no such job")
job <id> <name>: started  (a command asked for the job)
job <id> <name>: ok       (or "refused: <error>", "interrupted",
                           "failed: <message>", "cancelled", "no frame")
event <source id> <code>
key arrived: <logical> <physical> <modifiers>
commands: <names>
text <index>: <quoted text>
store <name> v<version>: <value>
scene <w>x<h>, focused <id or ->, echo <quoted>, preedit <quoted or ->, published <n>
view <id> <x>,<y> <w>x<h>: <quoted text>, scroll <offset>, selections <anchor>..<head> …
status <view id>: <face> <quoted text>, …   (or "-" for no field)
scene: none
loop: refused: <error>
```

`scene` prints the frame's size, the focused view (`-` while the frame does
not have the keyboard focus), the echo area, the input method's preedit
(`-` when there is none) and how many scenes have been published; then, for
each view in drawing order, its rectangle, the text of its snapshot, read
from the library, and the offsets of its scroll anchor and of each range of
its selection. After each view's line comes its status line, one entry a
field, each the field's face and its text: the name of the view's Vim
state in the face `status.state`, the buffer's name in the face
`status.name`, and, while the buffer is modified, `[+]` in the face
`status.modified`. A buffer that is not modified has no such field. This
is how a script sees a view's state, its buffer's name and whether the
buffer is modified.
`scene: none` means no scene has been published: the loop has not been
needed yet.

What the editor loop is refused is in the scene's echo area, as
`refused: <error>`: a commit the library refused, and a text or a snapshot
that was gone when the scene was made. A view whose buffer's text was
released, by a command, is left out of the scene, so the scene line is then
followed by fewer view lines, or none. `loop: refused: <error>` is for a
program of the loop that was itself refused. None is today; the line is
there so that one would not be dropped in silence.

A job's line is printed when the editor has dealt with its result: `ok` when
the handler's command ran, `refused` when the library refused that command
and `interrupted` when the interrupt key stopped it, each rolled back,
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
