# The headless mode

```sh
editor headless [--render] [<sysroot> <olean dir>] <config dir> <script file>
```

This is the editor with no window. It loads the config in a directory, runs
a script against it and prints what happened. `<sysroot>` is the Lean
toolchain's directory (`lean --print-prefix`) and `<olean dir>` the
directory of the editor package's `.olean` files
(`lean/.lake/build/lib/lean`). They are given both or neither, so three or
five paths are refused; from the build tree they are always given, and
every check of the gate but `bundle-test` gives them. Nothing is read from
the environment or the working directory.

## From an app bundle

An executable at `<bundle>/Contents/MacOS/<name>` is in a bundle, whatever
the bundle is called, and finds its modules there when the two directories
are left out:

```
Leanmacs.app/Contents/MacOS/editor
Leanmacs.app/Contents/Resources/lean/toolchain/lib/lean/   the toolchain's modules
Leanmacs.app/Contents/Resources/lean/editor/               the editor's .olean files
```

`Contents/Resources/lean/toolchain` is a sysroot: its modules are under its
`lib/lean`, as a toolchain's are. Two directories given on the command line
are used in place of the bundle's. Outside a bundle there is no toolchain to
fall back on, so two paths are refused, status 2, with
`editor: no Lean toolchain: give <sysroot> <olean dir> before the config directory, or run the executable from an app bundle`
before the usage. The resolution is a pure function of the executable's
path (`lean/Editor/ModuleLookup.lean`, pinned by
`ModelTest.moduleLookupChecks` and `ModelTest.headlessCommandLineChecks`),
and the executable's path is read from `IO.appPath`.

`mise run bundle-test`, part of the gate, lays out that bundle in a
temporary directory with `tools/stage-bundle.sh` and runs the headless
mode of a copy of `editor` there on `tests/headless/bundle`, with no
directory argument, an empty environment and a working directory outside
the bundle ([`the-gate.md`](the-gate.md)). To stage one by hand, from
`lean/`, into a directory of your own:

```sh
sysroot=$(lean --print-prefix)
.lake/build/bin/config-test bench-modules "$sysroot" .lake/build/lib/lean Editor > <dir>/closure
../tools/stage-bundle.sh --closure <dir>/closure <dir>/Leanmacs.app .lake/build/bin/editor \
  "$sysroot" .lake/build/lib/lean olean olean.server olean.private
```

Those are the modules `Editor` imports and the three file kinds importing
them reads ([`lean-runtime.md`](../design/lean-runtime.md), "What config
may import, measured"). Without `--closure` the script stages whole
top-level directories: `--roots` names the toolchain's (`Init,Std` by
default), and the package's `Editor` is always staged.

`mise run app` builds this layout for real, as `Leanmacs.app`
([`building.md`](building.md), "The app bundle"), and `mise run app-check`
runs this mode from a copy of it.

## Drawing it: `--render`

Without `--render` the display is a recorder: it keeps the scenes and
answers layout's questions with the display model's rule, and nothing is
drawn. With it, the display is the real binding over the library's layout
in cells of 8 by 16 pixels, bound to the library's headless render session:
a render loop on the CPU renderer, at each scene's size and a scale of 1,
which draws every frame published and keeps the frame journal. It is the
same editor loop the window mode runs; only the display and its drawing
differ. The scenes a script prints are the same either way. Three
directives read the drawing:

- **`agree`** asks the editor thread whether the last rows query about the
  focused view, at the anchor it was published with, answered the rows of
  the frame laid out of that scene: `agree view <id>: <n> rows asked from
  <anchor>, <m> in the frame: agrees`, or `…: disagrees: asked <rows>,
  frame <rows>`. The queries are the loop's own, made as it follows the
  cursor before each publish, and a scroll command's. Without `--render`:
  `agree: no frame`.
- **`idle <ms>`** settles, waits until the render loop is at rest, then
  counts what it draws and what it is handed over `<ms>` milliseconds:
  `idle <ms>: <d> frames drawn, <s> frames submitted`. Nothing should ask
  for a frame while nobody types, so both are 0. `idle 0` paces a key: the
  key's frame is drawn before the next is sent. Without `--render`:
  `idle <ms>: no render loop`.
- **`journal`** settles, waits for the loop to rest, and prints how many
  frames were presented since the last `journal` line, their
  `present - input` median, 99th percentile (nearest rank) and largest in
  microseconds, and the rows they rebuilt. Its numbers vary between runs,
  so it is for measuring (`mise run milestone-bench`), never for a
  fixture.

`tests/headless/milestone/` is milestone 1's fixture over the whole program:
`:e` on a 60-line source file, an evil session ending in `:w`, `agree`
after `C-f` and after the save, and `idle 1000`; `ffi-test` compares its
output and the saved file's bytes ([the-gate.md](the-gate.md)).

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
| `open-file` | Opens the file at the path that is its first argument in the window it is called with: it starts the job `load-file`, and when the file is loaded a buffer of its text, called by its base name, is shown there. A path a buffer already holds is shown at once. A file that is not there, or is refused for another reason, is said in the echo area, `cannot open <path>: <why>`, and the window shows what it showed. With no path it asks for one, with the prompt `Open file: `, whose text starts as the window's directory (its buffer's file's, else its workspace's root, else the working directory) and which lists that directory's entries, directories first, the directory typed so far listed again as it changes; and opens the answer, read as a typed path: a name that is not absolute under that directory, `~` under the home directory, which the headless mode does not know, and a restart after `//` or `/~/` as Emacs reads it. |
| `save-buffer` | Saves the buffer of the window it is called with to its file: it starts the job `save-file`, and when the file is written the echo area says `wrote <path>` and the buffer is no longer modified. A file that changed on disk since it was loaded is left as it is, and the echo area says `cannot save <path>: <why>`. With `true` as its first argument it writes whatever is on disk. |
| `reload-buffer` | Reloads the buffer of the window it is called with from its file: it starts the job `reload-file`, which loads the file and diffs it against the buffer's text off the editor thread, and the buffer then takes the file's text as one edit, with the cursor kept on the lines the diff kept, not modified, which one undo takes back. It is refused while the buffer has unsaved changes, saying `<name> has unsaved changes; :e! discards them`, unless its first argument is `true`. A text edited while the file loaded is reloaded once more, and then left, saying `<path> was edited while it reloaded; :e reloads it`. |
| `auto-reload-mode` | Turns auto-reload on with `true` first, off with `false`, and toggles it with neither, saying `auto-reload on` or `auto-reload off`. With it on, a job `follow-file` watches each file buffer's file, and another program's change reloads a buffer with no unsaved changes, or marks one with them `[changed on disk]` in face `mode-line.changed`, the mode line's `changed` segment. Off by default; config's `autoReload` in `setup` decides until a command does. |
| `edit-file` | What the ex names `e` and `e!` run: a leading `true` is the force; a path opens it as `open-file` does; with none it reloads the window's buffer as `reload-buffer` does when that has a file, and otherwise asks for a path. |

`run <name>` hands a command no argument, so a script cannot give
`open-file` its path that way. Config's own command calls the operation
the command is written with, `Files.open view path`, as the fifth fixture
below does; `Files.save buffer` is the save. Or the script runs
`open-file` with no path, commits the path into the minibuffer and accepts,
as the fixture `open-file` does. While a load or a save is in flight the editor
goes on answering: what is typed meanwhile is handled first.

The editor ships two more commands, compiled in, and one mode
(`lean/Editor/Minibuffer.lean`). A command asks for a string with
`prompt label continuation initial`, which opens the minibuffer and
returns at once; `continuation` names the command that receives the
answer, as its first argument.

| Command | Does |
|---|---|
| `minibuffer-accept` | Accepts the open prompt: it is closed, the focus goes back to the window it was asked from, and the command the prompt named runs with the answer. The answer is the chosen candidate, when one is chosen, and otherwise the minibuffer's text. With no prompt open it says so in the echo area. |
| `minibuffer-cancel` | Cancels the open prompt: it is closed, the focus goes back, and the command it named does not run. With no prompt open it says so. |
| `minibuffer-next` | Moves the choice to the next of the candidates the open prompt has listed: from nothing chosen to the first, and from the last to nothing chosen. The minibuffer's text is not changed. With nothing listed it does nothing, and with no prompt open it says so. |
| `minibuffer-previous` | The same, backward: from nothing chosen to the last, and from the first to nothing chosen. |
| `minibuffer-insert` | Puts a candidate in the input: the chosen one, or the first listed when nothing is chosen, replaces the minibuffer's text, the bar at its end, and the prompt stays open. With nothing listed for the text it does nothing, and with no prompt open it says so. |

One more compiled command switches the theme (`lean/Editor/Themes.lean`):

| Command | Does |
|---|---|
| `load-theme` | With a name as its first argument, makes the theme registered under it the theme in force, with no reload, and the next scene is drawn in it. With none it asks `Theme: `, with the registered themes' names as its candidates. A name nobody registered is said in the echo area, ``load-theme: no theme is registered as `<name>` ``, and changes nothing. The editor ships four themes, `default`, `solarized-dark`, `solarized-light` and `fairy-floss`; config registers more with `defineTheme` and names the one in force with `useTheme`. |

The mode `minibuffer` is the major mode of the minibuffer's buffer. It
puts four of the commands on the keys the input scheme has for the roles
`activate`, `quit`, `next-item` and `previous-item`; under the Vim scheme,
where typing in the minibuffer is text, they are on `<Enter>`, `<Escape>`,
`C-n` and `C-p`, and `<Tab>` runs `minibuffer-insert`, as Doom's vertico
binds them. Shift with `<Tab>` is not bound there. `<Enter>` on a chosen
candidate that is a directory goes into it, the prompt still open.

A prompt may be asked with candidates, from completion sources given as
values or registered by name with `defineSource`
(`prompt label continuation initial (sources := [.named "picks"])`). The
scene's `status` line of the minibuffer's view is the prompt's label alone,
in the face `minibuffer.prompt`, and the candidates are a view of their
own, printed after it: the candidate list, a text view with no selection,
one candidate a line, best first, at most ten, with its `decorations` line.
Each row is in the face `minibuffer.candidate`, the chosen one's in
`minibuffer.chosen`, and over it the ranges the typed text matched in
`minibuffer.match`, an annotation in `minibuffer.annotation`, and a group's
header in `minibuffer.group`. Once the list has shown rows it stays in the
scene while the prompt is open, with fewer lines, or none, when typing
cuts the matches: the minibuffer's place grows and never shrinks. Its view
takes a view id the first time it is drawn, so every view made after it
has one more.

And it ships evil, compiled in (`lean/Editor/Evil.lean` and the modules
beside it): the commands the Vim scheme's keys run, so the editor moves,
edits, undoes, repeats and scrolls with no config.

| Command | Keys | Does |
|---|---|---|
| `move` | `h j k l w b e W B E 0 ^ $ g g G`, each after a count | Moves the cursor by the motion the key names, as Vim does; in a visual state it moves the selection's head. |
| `insert`, `append`, `insert-line-start`, `append-line-end` | `i`, `a`, `I`, `A` | Run by its key, begins an insert: before the cursor, after it, at the line's first character that is not a blank, at the line's end. Run by its name it begins none (below). |
| `self-insert` | A key that prints, in insert state and in the minibuffer | Inserts what the key prints at the cursor. Everything typed until `<Escape>` is one step of the history. |
| `normal` | `<Escape>` | Run by its key, returns to normal state. From insert state the cursor steps back one character. Run by its name it leaves the view in the state it is in (below). |
| `visual`, `visual-line` | `v`, `V` | Run by its key, enters a visual state: a motion then extends the selection, by characters or by whole lines. Run by its name it enters none (below). |
| `operate` | `d`, `c`, `y`, each with a motion (`d w`, `c 2 e`), typed twice (`d d`), or in a visual state | Deletes, changes or yanks what the motion, the lines or the selection covers, as Vim does, into the unnamed register. `c` then begins an insert. An operator whose motion cannot be made (`d j` on the last line) gives up: nothing changes, and the echo area says `operate: down cannot move`. Where the motion moved before it failed (`d 3 b` that reaches an empty first line with a step left over) the cursor is left where the motion got to, nothing else changes, and the command is printed as having broken off. |
| `delete-char` | `x` | Deletes the character under the cursor, or a count of them, into the unnamed register. |
| `put-after`, `put-before` | `p`, `P` | Puts the unnamed register after or before the cursor, or below or above the line when the register holds whole lines. With nothing to put it gives up. |
| `open-below`, `open-above` | `o`, `O` | Opens an empty line below or above the cursor's line and begins an insert on it. |
| `undo`, `redo` | `u`, `C-r` | Undoes or redoes one step of the buffer's history, or a count of them, and puts the cursor where it was before the change, or where the change left it. |
| `repeat` | `.` | Makes the last change again at the cursor, with the text typed in it. A count before `.` replaces the change's count. It runs the command that is registered under the change's name when `.` is pressed, so config's command of that name is what it replays. Run by its name, which hands it no change, it gives up. |
| `scroll-down`, `scroll-up` | `C-d`, `C-u`, in normal state and the visual states | Scrolls the view and moves the cursor by half the rows the view fits, or by a count of rows. The cursor keeps its column. At the text's end the last row stays the last row shown and the cursor goes on to the last line. |
| `scroll-page-down`, `scroll-page-up` | `C-f`, `C-b` | The same, by the rows the view fits, or a count of that many. |
| `scroll-line-to-top`, `scroll-line-to-center`, `scroll-line-to-bottom` | `z t`, `z z`, `z b` | Scrolls the view so that the cursor's row is the first row shown, the middle one or the last. The cursor does not move. |

**Scrolling needs a frame with a height.** The headless frame is made 0 by
0, and a view of no height shows no row: there no view follows its cursor,
every scene prints `scroll 0`, and the seven scroll commands do nothing and
say nothing. A script gives the frame a size with `resize` (below). The
display is then a recorder that lays text out in cells 8 pixels across and
16 down, so `resize 640 480` is a view of 80 columns and 30 rows. From
then on, before each scene, a view whose cursor is not among the rows it
shows has its scroll anchor moved just far enough to show it, and the
`scroll` of its `view` line is the anchor's byte offset. A command sets
how many rows are kept round the cursor with `setScrollMargin`
(`lean/Editor/Api.lean`); no command that ships sets it, and it is 0.

`j` and `k` need no frame size. They ask the recorder about a line laid
out unwrapped, so they aim for the display column in a frame of 0 by 0
too: on the recorder a tab reaches to the next multiple of 8 cells and a
wide character is two cells.

**Registers.** A yank and a deletion set the unnamed register. `"` and
then `+` before an operator, `x`, `p` or `P` names the clipboard: the
headless host has no window system, so it keeps a clipboard of its own in
the process, which starts holding no text and which no other program
sees. What one command writes there the next reads. Any other register
name gives the command up.

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

And it ships the ex command line, compiled in (`lean/Editor/Ex.lean`): a
prompt labelled `:`, whose answer is run as a named ex command.

| Command | Does |
|---|---|
| `ex` | Opens the ex line: a prompt labelled `:`. When it is accepted, the line's first word is looked up as an ex name and the command it is bound to runs, with the rest of the line as its first argument if the name takes one. The Vim scheme's `:` key runs it. With a string as its first argument it runs that line with no prompt. |
| `quit` | Asks the editor to quit. It is refused while a buffer that holds a file has unsaved changes, and says `quit: <name> has unsaved changes`. A buffer with no file, the scratch buffer among them, never blocks it. While a save is in flight the editor quits once that save's result has been delivered. |
| `save-and-quit` | Saves the buffer of the window it is called with, as `save-buffer` does, and asks the editor to quit if the save started. The quit waits for the save. |
| `reload-config` | Asks for the config to be reloaded, as the `reload` directive does. It says nothing: the reload's report is printed. |

And it ships the buffer commands, compiled in (`lean/Editor/Buffers.lean`),
which the ex names `b`, `ls` and `bd` run.

| Command | Does |
|---|---|
| `switch-buffer` | Shows another open buffer in the window it is called with: the buffer of exactly the name that is its first argument, or else the first of the open buffers' names, in the prompt's order, that the style of the category `buffer` matches it with (the best fuzzy match by default). With no string it asks, with a prompt labelled `Buffer: ` whose candidates are the open buffers' names, most recently used first and the window's own buffer last. Nothing matching says `switch-buffer: no buffer matches <text>`. |
| `list-buffers` | Shows a buffer called `buffer-list` (`buffer-list<2>` and so on where another buffer, such as a file's, has that name), with no file, whose text lists the open buffers, most recently used first: `+` for one with unsaved changes, its name, and its path for a buffer with a file. A later list replaces the text. |
| `close-buffer` | Closes the buffer its first argument names, or the window's buffer: every window that showed it shows the most recently used buffer left, and closing the last leaves an empty `scratch`. It is refused while the buffer holds a file and has unsaved changes, and says `close-buffer: <name> has unsaved changes`; and while a save of the buffer is in flight, saying `close-buffer: <name> is being saved; try again when it is written`. |

| Ex name | Runs | Takes |
|---|---|---|
| `w` | `save-buffer` | Nothing |
| `w!` | `save-buffer` with `true` | Nothing: writes the buffer over whatever the file on disk is |
| `e <path>` | `edit-file` | The rest of the line, whole, as the path. With none it reloads the window's file, refused while the buffer has unsaved changes; on a buffer with no file it asks for a path |
| `e! <path>` | `edit-file` with `true` | As `e`, but with none the reload discards unsaved changes, as one step `u` undoes |
| `autoread` | `auto-reload-mode` with `true` | Nothing: turns auto-reload on |
| `noautoread` | `auto-reload-mode` with `false` | Nothing: turns it off, ending every follow job |
| `q` | `quit` | Nothing |
| `wq` | `save-and-quit` | Nothing |
| `reload` | `reload-config` | Nothing |
| `b <buffer>` | `switch-buffer` | The rest of the line, the buffer's name or a pattern. With none it asks for one |
| `ls` | `list-buffers` | Nothing |
| `bd <buffer>` | `close-buffer` | The rest of the line, a buffer's name. With none it closes the window's buffer |

- A line is its first word and the rest. White space round the line and
  after the name is dropped; the rest is one argument, spaces included.
  An empty line runs nothing.
- A name nobody bound says `<name>: not an ex command` in the echo area,
  and an argument for a name that takes nothing says
  `<name>: takes no argument`. The editor goes on. So `w!` and `:w` are
  unknown names: `!`, ranges and a leading colon are not read.
- The command a line runs is run like any command: what became of it is
  in the echo area under its own name.
- An accepted line is three commands, one after the other, each followed
  by a scene: `minibuffer-accept`, `ex` with the line, and the bound
  command.
- A script runs a line with `run ex`, a `commit` of the line and `key
  <Enter> Enter -`, as the eighth fixture below does.

`setup` binds an ex name to a command's name with `exCommand`, by default
taking nothing:

```lean
def setup : SetupM Unit := do
  commandWith "greet-named" greetNamed
  exCommand "greet" "greet-named" (takes := .text)
```

Config's binding of a name the editor ships, `w` say, runs in its place
until a reload drops it. A name that is empty or holds white space is
refused, and so is a `setup` that binds one ex name twice. `show` does not
list ex names.

Every default key of the Vim scheme names a command the editor ships. A
key that config binds to a name nothing registers says
`<name>: no such command` in the echo area.

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

**Headless time is fake.** The headless mode's job clock, which every job's
wait, every time limit and the pause of completion at point wait on, is a
fake clock: real time never moves it, and the script moves it with
`advance <milliseconds>`. So a job that sleeps ends only once the script
advances past its sleep, and a pause fires only when a script advances, and
saved outputs stay deterministic. An `advance` waits for a wait due within
its milliseconds before it moves the clock, so `advance 1` after `spawn
count` cannot move the clock before `count` is in its sleep. `idle
<milliseconds>` still waits real milliseconds, for the render loop, which is
the render thread's and not the job clock's. The window mode keeps the real
timers.

| Directive | Does |
|---|---|
| `reload` | Asks for the config to be reloaded. Elaboration runs in the background, and the editor goes on answering. The command `reload-config`, and so the ex line `reload`, asks the same. |
| `settle` | Waits, for up to 30 seconds, until everything asked so far has been handled and no reload is running. |
| `run <name>` | Runs the command registered under that name, through the editor loop, as a key would: with the focused window, guarded against the interrupt key, and rolled back if it does not run to its end. It is no key, so the input scheme's state is as it was: a command that a key enters a Vim state with enters none (the table of evil's commands, above). |
| `spawn <name>` | Starts the job registered under that name. It runs in the background, and the editor goes on answering. |
| `join` | Waits, for up to 30 seconds, until everything asked so far has been handled and no job is running. |
| `advance <milliseconds>` | Moves the headless mode's job clock on by that many milliseconds, once it holds a wait due within them (for up to 30 seconds), completing every wait then due: a job's sleep, a time limit, the pause of completion at point. It sends nothing to the editor thread and prints nothing, so a scene count is unchanged by it. One with no wait due within the time runs out, saying `the advance on line N found no wait due within M ms on the clock within the patience`. Anything but one number is refused. |
| `show` | Prints the commands, the texts and the stores. |
| `key <logical> <physical> <modifiers>` | Sends a press of a key, with no text, as the window would report it: through the library's window input, in order with what was asked before. `<logical>` is one character (`a`) or a named key in angle brackets (`<Escape>`, a W3C UI Events `key` name); `<physical>` is a W3C UI Events `code` (`KeyA`) or `-`; `<modifiers>` is `shift`, `control`, `alt` and `super` joined with `+`, or `-`. The editor prints `key arrived:` with the three. The editor loop steps the key through its input scheme, and runs the command a completed sequence is bound to. |
| `commit <text>` | Sends the rest of the line, trimmed, as an input method's composition would end with it, the same way as `key`. The editor loop inserts it at the focused window's cursors where the view takes typed text: under the Vim scheme, in insert state and in the minibuffer. In normal state it is dropped. A `commit` with no text is refused. |
| `resize <width> <height>` | Sends a resize of the frame to that many physical pixels across and down, at a scale of 1, the same way as `key`. The next scene's frame has that size and its views are laid out in it. Anything but two numbers is refused. Until a script resizes, the frame is 0 by 0, no view shows a row, and nothing scrolls (above). |
| `scene` | Prints the last scene the editor loop published: the frame, then each view and the text its snapshot holds, then, for a view that has any, a line `decorations <view>: <face> <start>..<stop> ...` (the matches of the last search, in `search-match`), and after each view its status line: the mode line's left fields, then ` \| ` and its right ones, each with its face, its text and its padding. Under the default order that is the view's Vim state as a badge, its buffer's name, a modified mark while the buffer is modified, a changed mark while a check has found its file changed on disk, and the directory its file was opened in, then its line:col and its position. While a prompt is open the minibuffer's view is printed after the windows', with the prompt text as its status line. |

With the fixture the gate uses (`tests/headless`):

```console
$ cd lean
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/script
reload 1: installed, 2 chunks, 1 commands
run greet: ok
run missing: no such command
commands: open-file save-buffer edit-file reload-buffer auto-reload-mode minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all ex quit save-and-quit reload-config switch-buffer list-buffers close-buffer toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme workspace-current greet
text 0: ""
text 1: "hello, world"
spawn count: job 1
job 1 count: ok
commands: open-file save-buffer edit-file reload-buffer auto-reload-mode minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all ex quit save-and-quit reload-config switch-buffer list-buffers close-buffer toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme workspace-current greet
text 0: ""
text 1: "hello, world"
text 2: "counted 42"
```

Text 0 is the scratch buffer's: the editor loop makes its frame, and that
buffer, for the first command it runs. `open-file`, `save-buffer`,
`edit-file`, `reload-buffer` and `auto-reload-mode`, `minibuffer-accept`, `minibuffer-cancel`, `minibuffer-next`,
`minibuffer-previous`, `minibuffer-insert`, `minibuffer-delete-backward`,
`minibuffer-delete-to-start` and `minibuffer-ask`, evil's thirty-seven,
from `move` to `select-all`, the ex line's four, from `ex` to
`reload-config`, the three buffer commands, from `switch-buffer` to
`close-buffer`, the frame's two, `toggle-fullscreen` and
`minimise-window`, and `load-theme`, are
the commands the editor ships, compiled in: `show` lists them before
config's.

The gate runs a second script on the same config, `tests/headless/keys-script`,
whose output must be exactly `tests/headless/keys-expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/keys-script
key arrived: a KeyA shift+control
key arrived: <Escape> Escape -
```

`count` sleeps on the headless mode's clock, so the script advances it
(`advance 1`) before its `join`.

A third script, `tests/headless/scene-script`, presses `i`, commits text
and asks for the scene, then reloads and runs a job, advancing the clock
past its sleep (`advance 1`) before its `join`; its output must be
exactly `tests/headless/scene-expected`. A committed text is typed text, so
it is inserted in insert state, which `i` enters; in normal state it would
be dropped:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/scene-script
key arrived: i KeyI -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 2, theme "default"
view 0 0,0 0x0: "hello", scroll 0, selections 5..5, padding 8 8
status 0: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:6" +4, mode-line.secondary "All" +4
reload 1: installed, 2 chunks, 1 commands
spawn count: job 1
job 1 count: ok
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 9, theme "default"
view 0 0,0 0x0: "hello", scroll 0, selections 5..5, padding 8 8
status 0: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:6" +4, mode-line.secondary "All" +4
```

A fourth, `tests/headless/dispatch/script`, runs on a config of its own,
`tests/headless/dispatch/config`, which registers `spin`, a command that
inserts `spin` and then asks the text its revision a thousand million
times, and `mark`, which inserts `mark`, and binds `C-c s` and `C-c m` to
them. It sends `C-c s` and then `C-g`, the interrupt key, which stops
`spin` and rolls its insertion back, and is then looked up as any key is:
under the Vim scheme it runs `keyboard-quit`, which, with no `:!` running,
says `Quit`. Then `C-c m`, which runs to its end.
The config also registers the job `double` and the command `ask` shown
above, on `C-c d`: the script sends `C-c d`, advances the headless mode's
clock past the job's sleep (`advance 1`), waits for the job with `join`,
and asks for the scene, whose echo area holds what the job's command said.
Its output must be exactly `tests/headless/dispatch/expected`; were `spin`
not stopped, the gate's time limit would end the run:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/dispatch/config ../tests/headless/dispatch/script
reload 1: installed, 1 chunks, 3 commands
key arrived: c KeyC control
key arrived: s KeyS -
key arrived: g KeyG control
scene 0x0, focused 0, echo "Quit", echo padding 8, preedit -, published 3, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: c KeyC control
key arrived: m KeyM -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 6, theme "default"
view 0 0,0 0x0: "mark", scroll 0, selections 4..4, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:5" +4, mode-line.secondary "All" +4
key arrived: c KeyC control
key arrived: d KeyD -
job 1 double: started
job 1 double: ok
scene 0x0, focused 0, echo "doubled to 42", echo padding 8, preedit -, published 11, theme "default"
view 0 0,0 0x0: "mark", scroll 0, selections 4..4, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:5" +4, mode-line.secondary "All" +4
```

The status line after the first scene's view has the state's badge and the
buffer's name: `spin` was rolled back, so the buffer is not modified. After
`mark` it has the modified mark too, and its line:col is after the text.

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
scene 0x0, focused 0, echo "scratch has no file to save to", echo padding 8, preedit -, published 1, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
run open-relative: ok
job 1 load-file: started
job 1 load-file: ok
scene 0x0, focused 0, echo "cannot open notes/relative.txt: the path is not absolute", echo padding 8, preedit -, published 5, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
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
area. Its output must be exactly `tests/headless/prompt/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/prompt/config ../tests/headless/prompt/script
reload 1: installed, 1 chunks, 2 commands
run ask-name: ok
key arrived: ! Digit1 shift
scene 0x0, focused 1, echo "", echo padding 8, preedit -, published 2, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 0,0 0x0: "Ada!", scroll 0, selections 4..4, padding 8 0
status 1: minibuffer.prompt "Name: "
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "hello Ada!", echo padding 8, preedit -, published 5, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
run ask-name: ok
key arrived: <Escape> Escape -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 8, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
```

A seventh, `tests/headless/evil-script`, runs on the first fixture's config
directory and loads none of it: it has no `reload`. So every command its
keys run is one the editor ships. It presses `i`, which begins an insert,
then the five keys of `hello`, each typed text; `<Escape>`, which returns
to normal state with the cursor on the last character typed; and `0`,
which is a motion there. It goes on to search with `/`, `n` and `N`, to
type a pair of brackets after the text and go back over it with `%`, and
to delete inside it with `d i (`, so the library's bracket walk answers
both. Its output must be exactly
`tests/headless/evil-expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/evil-script
key arrived: i KeyI -
key arrived: h KeyH -
key arrived: e KeyE -
key arrived: l KeyL -
key arrived: l KeyL -
key arrived: o KeyO -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 6, theme "default"
view 0 0,0 0x0: "hello", scroll 0, selections 5..5, padding 8 8
status 0: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:6" +4, mode-line.secondary "All" +4
key arrived: <Escape> Escape -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 8, theme "default"
view 0 0,0 0x0: "hello", scroll 0, selections 4..4, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:5" +4, mode-line.secondary "All" +4
key arrived: 0 Digit0 -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 10, theme "default"
view 0 0,0 0x0: "hello", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
```

The status line's first field is the badge of the view's Vim state, in the
face `mode-line.state.<state>`: `INSERT` while the keys are typed text, and
`NORMAL` before `i` and after `<Escape>`. In insert state the selection is a bar
between characters, after what was typed; in normal state it is on a
character. `scene` prints a selection's two ends and not its shape or the
cursor's.

An eighth, `tests/headless/ex/script`, runs the ex command line on the
first fixture's config directory, of which it loads nothing. Each line is
the prompt opened, a `commit` of the line, and `<Enter>`. The first and
the last open it as a user does, with the `:` key (`key : Semicolon
shift`), which the Vim scheme's normal state binds to `ex` and hands a
count and a register; the second opens it with `run ex`. `bogus` is a name nobody bound; `w` runs `save-buffer`, and the
scratch buffer has no file. The third line is `e`, and a scene is printed
with the prompt open: the ex line's candidates are the bound ex names, so
the candidate list, view 2, lists `e`, which is the text, and then the
other names `e` matches, at most ten, each with the range `e` matched in
`minibuffer.match`. `<Tab>` puts the first listed in the input, `e`, the
text already there, and `<Enter>` runs it: `e` with no path asks for one
with the file prompt, which starts with the executable's working directory
and lists it, a machine's path, so the script waits for its listing with
`join`, prints none of it, and `<Escape>` cancels it before the next
scene. `q` quits the editor. The loop ends at that
last `<Enter>`, so the `scene` line the script has after it is not run,
and the exit status is 0. Its output must be exactly
`tests/headless/ex/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/ex/script
key arrived: : Semicolon shift
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "bogus: not an ex command", echo padding 8, preedit -, published 4, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
run ex: ok
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "scratch has no file to save to", echo padding 8, preedit -, published 10, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: : Semicolon shift
scene 0x0, focused 4, echo "", echo padding 8, preedit -, published 13, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 4 0,0 0x0: "e", scroll 0, selections 1..1, padding 8 0
status 4: minibuffer.prompt ":"
view 2 0,0 0x0: "e\ne!\nnext-error\nprevious-error\nautoread\nnoautoread\nreload\ncompile\ncompile-command\nrecompile", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..1 minibuffer.match 0..1 minibuffer.candidate 2..4 minibuffer.match 2..3 minibuffer.candidate 5..15 minibuffer.match 6..7 minibuffer.candidate 16..30 minibuffer.match 18..19 minibuffer.candidate 31..39 minibuffer.match 36..37 minibuffer.candidate 40..50 minibuffer.match 47..48 minibuffer.candidate 51..57 minibuffer.match 52..53 minibuffer.candidate 58..65 minibuffer.match 64..65 minibuffer.candidate 66..81 minibuffer.match 72..73 minibuffer.candidate 82..91 minibuffer.match 83..84
status 2: -
key arrived: <Tab> Tab -
key arrived: <Enter> Enter -
job 1 files: started
job 1 files: ok
job 1 files: ok
key arrived: <Escape> Escape -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 22, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: : Semicolon shift
key arrived: <Enter> Enter -
```

Four scenes are published between the first `:` key and the first
`scene`: for `ex`, for the commit, for the accept command and for `ex`
with the line. The second line adds a fifth, for `save-buffer`.

A ninth, `tests/headless/candidates/script`, asks for a prompt with
candidates and chooses one, on the config in
`tests/headless/candidates/config`, with the library's fuzzy matcher.
Config's `pick` asks `Pick: ` with the candidates `wq`, `edit` and `w`.
With `w` typed, the candidate list, view 2, lists `w` and then `wq`: the
library scores the two the same and `wq` came first, so only the rule
that a candidate that is the text is first orders them. `C-n` twice
chooses `wq`, which is then in the face `minibuffer.chosen`, and `<Enter>`
gives config's `picked` that candidate and not the typed text. With `z`
typed nothing is listed, so the second prompt's list, which showed three
rows for the empty initial text, is empty but stays in the scene; `<Tab>`
puts nothing in the input, and `picked` receives `z`. Last, with `e`
typed, `<Tab>` puts the first listed, `edit`, in the input, the bar at its
end and the prompt still open, and `<Enter>` gives `picked` that text. Its output must be exactly `tests/headless/candidates/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/candidates/config ../tests/headless/candidates/script
reload 1: installed, 1 chunks, 2 commands
run pick: ok
key arrived: w KeyW -
scene 0x0, focused 1, echo "", echo padding 8, preedit -, published 2, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 0,0 0x0: "w", scroll 0, selections 1..1, padding 8 0
status 1: minibuffer.prompt "Pick: "
view 2 0,0 0x0: "w\nwq", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..1 minibuffer.match 0..1 minibuffer.candidate 2..4 minibuffer.match 2..3
status 2: -
key arrived: n KeyN control
key arrived: n KeyN control
scene 0x0, focused 1, echo "", echo padding 8, preedit -, published 5, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 0,0 0x0: "w", scroll 0, selections 1..1, padding 8 0
status 1: minibuffer.prompt "Pick: "
view 2 0,0 0x0: "w\nwq", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..1 minibuffer.match 0..1 minibuffer.chosen 2..4 minibuffer.match 2..3
status 2: -
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "picked wq", echo padding 8, preedit -, published 8, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
run pick: ok
key arrived: z KeyZ -
scene 0x0, focused 3, echo "", echo padding 8, preedit -, published 11, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 3 0,0 0x0: "z", scroll 0, selections 1..1, padding 8 0
status 3: minibuffer.prompt "Pick: "
view 2 0,0 0x0: "", scroll 0, selections , padding 8 0
status 2: -
key arrived: <Tab> Tab -
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "picked z", echo padding 8, preedit -, published 15, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
run pick: ok
key arrived: e KeyE -
key arrived: <Tab> Tab -
scene 0x0, focused 4, echo "", echo padding 8, preedit -, published 19, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 4 0,0 0x0: "edit", scroll 0, selections 4..4, padding 8 0
status 4: minibuffer.prompt "Pick: "
view 2 0,0 0x0: "edit", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..4 minibuffer.match 0..4
status 2: -
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "picked edit", echo padding 8, preedit -, published 22, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
```

A tenth, `tests/headless/themes/script`, switches the theme, on the config
in `tests/headless/themes/config`, which defines two themes, `first` and
`second`, and names `first` (`useTheme`). The first scene is drawn in
`first`. `load-theme` is run, `second` committed into its minibuffer and
`<Enter>` accepts: the theme is switched with no reload, and the next scene
is drawn in `second`. The switch is followed by a scene of its own, after
the scene the accepted command's step published, so the count of scenes
goes up by one more. Then `load-theme` is run again, and `solarized-dark`,
a theme the editor ships, is committed and accepted: the next scene is
drawn in it. Last, `fairy-floss`, another shipped theme, is loaded the same
way, and the next scene is drawn in it. Its output must be exactly
`tests/headless/themes/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/themes/config ../tests/headless/themes/script
reload 1: installed, 1 chunks, 0 commands
key arrived: <Escape> Escape -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 1, theme "first"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
run load-theme: ok
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 7, theme "second"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
run load-theme: ok
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 13, theme "solarized-dark"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
run load-theme: ok
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 19, theme "fairy-floss"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
```

An eleventh, `tests/headless/shipped-themes/script`, runs on the config in
`tests/headless/shipped-themes/config`, which names a shipped theme,
`solarized-light` (`useTheme`): compiled code registers the shipped themes
before any config, so the name is found when the config is installed. The
first scene is drawn in `solarized-light`. Then `load-theme` is answered
with `fairy-floss`, and the next scene is drawn in it. Its output must be
exactly `tests/headless/shipped-themes/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/shipped-themes/config ../tests/headless/shipped-themes/script
reload 1: installed, 1 chunks, 0 commands
key arrived: <Escape> Escape -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 1, theme "solarized-light"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
run load-theme: ok
key arrived: <Enter> Enter -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 7, theme "fairy-floss"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
```

A twelfth, `tests/headless/mode-line/script`, runs on the config in
`tests/headless/mode-line/config`, which defines a segment of its own,
`greeting` (`defineSegment`), and lists the mode line for each side
(`modeLine`), naming one segment nobody registered, `nope`. The reload is
installed, says the unknown segment on a line of its own and in the echo
area, and draws the rest; then the scenes in normal state, in insert state
with `abc` typed, after `<Escape>`, and with the ex prompt open, where the
asking window keeps its badge and the candidate list shows the first ten
ex names. Its output must be exactly
`tests/headless/mode-line/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/mode-line/config ../tests/headless/mode-line/script
reload 1: installed, 1 chunks, 0 commands
segment: no segment is registered as `nope`
key arrived: <F5> F5 -
scene 0x0, focused 0, echo "reload: no segment is registered as `nope`", echo padding 8, preedit -, published 1, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "hi" +4, mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: i KeyI -
key arrived: a KeyA -
key arrived: b KeyB -
key arrived: c KeyC -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 6, theme "default"
view 0 0,0 0x0: "abc", scroll 0, selections 3..3, padding 8 8
status 0: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "hi" +4, mode-line.secondary "1:4" +4, mode-line.secondary "All" +4
key arrived: <Escape> Escape -
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 8, theme "default"
view 0 0,0 0x0: "abc", scroll 0, selections 2..2, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "hi" +4, mode-line.secondary "1:3" +4, mode-line.secondary "All" +4
key arrived: : Semicolon shift
scene 0x0, focused 1, echo "", echo padding 8, preedit -, published 10, theme "default"
view 0 0,0 0x0: "abc", scroll 0, selections 2..2, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "hi" +4, mode-line.secondary "1:3" +4, mode-line.secondary "All" +4
view 1 0,0 0x0: "", scroll 0, selections 0..0, padding 8 0
status 1: minibuffer.prompt ":"
view 2 0,0 0x0: "w\nw!\ne\ne!\nautoread\nnoautoread\nq\nwq\nreload\nb", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..1 minibuffer.candidate 2..4 minibuffer.candidate 5..6 minibuffer.candidate 7..9 minibuffer.candidate 10..18 minibuffer.candidate 19..29 minibuffer.candidate 30..31 minibuffer.candidate 32..34 minibuffer.candidate 35..41 minibuffer.candidate 42..43
status 2: -
```

A thirteenth, `tests/headless/padding/script`, runs on the config in
`tests/headless/padding/config`, which sets the frame padding to 12 points
(`framePadding 12`). After a resize to 640 by 480 the window's view is
padded 12 across and 12 down and the echo 12, the padding, since the
headless window's corners are square; with the ex prompt open the
minibuffer's view and the candidate list's above it are padded 12 across
and none down, and the window is shorter by the list's ten rows. Its output must be
exactly `tests/headless/padding/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/padding/config ../tests/headless/padding/script
reload 1: installed, 1 chunks, 0 commands
scene 640x480, focused 0, echo "", echo padding 12, preedit -, published 1, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 12 12
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: : Semicolon shift
scene 640x480, focused 1, echo "", echo padding 12, preedit -, published 3, theme "default"
view 0 0,0 640x288: "", scroll 0, selections 0..0, padding 12 12
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 0,448 640x32: "", scroll 0, selections 0..0, padding 12 0
status 1: minibuffer.prompt ":"
view 2 0,288 640x160: "w\nw!\ne\ne!\nautoread\nnoautoread\nq\nwq\nreload\nb", scroll 0, selections , padding 12 0
decorations 2: minibuffer.candidate 0..1 minibuffer.candidate 2..4 minibuffer.candidate 5..6 minibuffer.candidate 7..9 minibuffer.candidate 10..18 minibuffer.candidate 19..29 minibuffer.candidate 30..31 minibuffer.candidate 32..34 minibuffer.candidate 35..41 minibuffer.candidate 42..43
status 2: -
```

A fourteenth, `tests/headless/monocle/script`, runs on the config in
`tests/headless/monocle/config`, which chooses the monocle layout
(`layout .monocle`) and binds `C-c s` to a command that splits the window
it is pressed in and `C-c o` to one that focuses the next window of the
frame's list. After a resize to 640 by 480 each scene has one window's
view, `640x464`, the area above the bottom row: view 0, view 0 again after
the split, since the focus stays, then view 1 once `C-c o` focuses it; and
with the ex prompt open, view 1, the prompt's asker, `640x288`, above the
candidate list's ten rows, `640x160`, and the minibuffer's view. Its output must be exactly
`tests/headless/monocle/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/monocle/config ../tests/headless/monocle/script
reload 1: installed, 1 chunks, 2 commands
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 1, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: c KeyC control
key arrived: s KeyS -
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 4, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: c KeyC control
key arrived: o KeyO -
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 7, theme "default"
view 1 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: : Semicolon shift
scene 640x480, focused 2, echo "", echo padding 8, preedit -, published 9, theme "default"
view 1 0,0 640x288: "", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 2 0,448 640x32: "", scroll 0, selections 0..0, padding 8 0
status 2: minibuffer.prompt ":"
view 3 0,288 640x160: "w\nw!\ne\ne!\nautoread\nnoautoread\nq\nwq\nreload\nb", scroll 0, selections , padding 8 0
decorations 3: minibuffer.candidate 0..1 minibuffer.candidate 2..4 minibuffer.candidate 5..6 minibuffer.candidate 7..9 minibuffer.candidate 10..18 minibuffer.candidate 19..29 minibuffer.candidate 30..31 minibuffer.candidate 32..34 minibuffer.candidate 35..41 minibuffer.candidate 42..43
status 3: -
```

A fifteenth, `tests/headless/two-windows/script`, runs on the config in
`tests/headless/two-windows/config`, which keeps the default layout and
binds the same two keys as the monocle fixture's (each fixture's config
directory is self-contained). In a frame of 640 by 120 it types twelve
lines, more than a window shows, goes back to the first, and splits the
window: views 0 and 1 are side by side, `0,0 320x104` and `320,0 320x104`,
on one buffer, both at scroll 0. Then view 1 is focused and `G` takes its
cursor to the last line, its anchor following it down, and view 0, focused
again, appends `,world` to its first line. The last scene shows both views
with the edit; view 0 is still at scroll 0 with its cursor on the first
line, and view 1 at the last line's start, with its anchor further down,
each moved by the edit. Its output must be exactly
`tests/headless/two-windows/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/two-windows/config ../tests/headless/two-windows/script
reload 1: installed, 1 chunks, 2 commands
key arrived: i KeyI -
key arrived: <Enter> Enter -
key arrived: <Enter> Enter -
key arrived: <Enter> Enter -
key arrived: <Enter> Enter -
key arrived: <Enter> Enter -
key arrived: <Enter> Enter -
key arrived: <Enter> Enter -
key arrived: <Enter> Enter -
key arrived: <Enter> Enter -
key arrived: <Enter> Enter -
key arrived: <Enter> Enter -
key arrived: <Escape> Escape -
key arrived: g KeyG -
key arrived: g KeyG -
key arrived: c KeyC control
key arrived: s KeyS -
scene 640x120, focused 0, echo "", echo padding 8, preedit -, published 30, theme "default"
view 0 0,0 320x104: "hello\n02\n03\n04\n05\n06\n07\n08\n09\n10\n11\n12", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "Top" +4
view 1 320,0 320x104: "hello\n02\n03\n04\n05\n06\n07\n08\n09\n10\n11\n12", scroll 0, selections 0..0, padding 8 8
status 1 in mode-line.inactive: mode-line.inactive "scratch" +4, mode-line.inactive "●" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "Top" +4
key arrived: c KeyC control
key arrived: o KeyO -
key arrived: G KeyG shift
key arrived: c KeyC control
key arrived: o KeyO -
key arrived: A KeyA shift
key arrived: <Escape> Escape -
scene 640x120, focused 0, echo "", echo padding 8, preedit -, published 39, theme "default"
view 0 0,0 320x104: "hello,world\n02\n03\n04\n05\n06\n07\n08\n09\n10\n11\n12", scroll 0, selections 10..10, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:11" +4, mode-line.secondary "Top" +4
view 1 320,0 320x104: "hello,world\n02\n03\n04\n05\n06\n07\n08\n09\n10\n11\n12", scroll 33, selections 42..42, padding 8 8
status 1 in mode-line.inactive: mode-line.inactive "scratch" +4, mode-line.inactive "●" +4 | mode-line.inactive "12:1" +4, mode-line.inactive "Bot" +4
```

A sixteenth, `tests/headless/manual-splits/script`, runs on the config in
`tests/headless/manual-splits/config`, which chooses the manual split layout
(`layout Layout.manual`) and binds no key: the window commands are reached
by the keys the Vim scheme ships under `C-w`. In a frame of 640 by 480,
`C-w s` puts view 1 above view 0 and focuses it, each `0,0 640x232` and
`0,232 640x232`; `C-w v` puts view 2 left of view 1 and focuses it, each
`320x232`, view 0's row as it was; `C-w j` focuses view 0, below; `C-w C-w`
wraps from view 0, the last in Vim's numbering, to view 2, the first; and
`C-w C-c` three times closes view 2 and view 1 and is refused on view 0,
the last, which takes the whole tiled area, with
`window-close: the last window cannot be closed` in the echo area. Its
output must be exactly `tests/headless/manual-splits/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/manual-splits/config ../tests/headless/manual-splits/script
reload 1: installed, 1 chunks, 0 commands
key arrived: w KeyW control
key arrived: s KeyS -
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 3, theme "default"
view 1 0,0 640x232: "", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 0 0,232 640x232: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
key arrived: w KeyW control
key arrived: v KeyV -
scene 640x480, focused 2, echo "", echo padding 8, preedit -, published 6, theme "default"
view 2 0,0 320x232: "", scroll 0, selections 0..0, padding 8 8
status 2: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 320,0 320x232: "", scroll 0, selections 0..0, padding 8 8
status 1 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 0 0,232 640x232: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
key arrived: w KeyW control
key arrived: j KeyJ -
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 9, theme "default"
view 2 0,0 320x232: "", scroll 0, selections 0..0, padding 8 8
status 2 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 1 320,0 320x232: "", scroll 0, selections 0..0, padding 8 8
status 1 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 0 0,232 640x232: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: w KeyW control
scene 640x480, focused 2, echo "", echo padding 8, preedit -, published 12, theme "default"
view 2 0,0 320x232: "", scroll 0, selections 0..0, padding 8 8
status 2: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 320,0 320x232: "", scroll 0, selections 0..0, padding 8 8
status 1 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 0 0,232 640x232: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
key arrived: w KeyW control
key arrived: c KeyC control
key arrived: w KeyW control
key arrived: c KeyC control
key arrived: w KeyW control
key arrived: c KeyC control
scene 640x480, focused 0, echo "window-close: the last window cannot be closed", echo padding 8, preedit -, published 19, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
```

A seventeenth, `tests/headless/insert-window-keys/script`, runs on the
config in `tests/headless/insert-window-keys/config`, which binds every key
of the Vim scheme's `C-w` table with `bindKey` (`for (keys, name) in
Vim.Default.windowKeys do bindKey keys name`) and keeps the default layout.
A binding of config's holds in every Vim state, and its `C-w` prefix
shadows insert state's own `C-w`, the word delete. `C-w v` splits view 0:
under master-and-stack the new window goes right after it, so view 1 is
the stack, on the right, and focused. `i` and a committed `ab` type in
view 1; `C-w h` in insert state focuses view 0, on the left, and `C-w l`
focuses view 1 again, whose status line still says `INSERT`; a committed
`c` then goes after `ab`, and both views show `abc`. Its output must be
exactly `tests/headless/insert-window-keys/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/insert-window-keys/config ../tests/headless/insert-window-keys/script
reload 1: installed, 1 chunks, 0 commands
key arrived: w KeyW control
key arrived: v KeyV -
key arrived: i KeyI -
key arrived: w KeyW control
key arrived: h KeyH -
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 7, theme "default"
view 0 0,0 320x464: "ab", scroll 0, selections 2..2, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:3" +4, mode-line.secondary "All" +4
view 1 320,0 320x464: "ab", scroll 0, selections 2..2, padding 8 8
status 1 in mode-line.inactive: mode-line.inactive "scratch" +4, mode-line.inactive "●" +4 | mode-line.inactive "1:3" +4, mode-line.inactive "All" +4
key arrived: w KeyW control
key arrived: l KeyL -
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 10, theme "default"
view 0 0,0 320x464: "ab", scroll 0, selections 2..2, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4, mode-line.inactive "●" +4 | mode-line.inactive "1:3" +4, mode-line.inactive "All" +4
view 1 320,0 320x464: "ab", scroll 0, selections 2..2, padding 8 8
status 1: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:3" +4, mode-line.secondary "All" +4
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 12, theme "default"
view 0 0,0 320x464: "abc", scroll 0, selections 3..3, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4, mode-line.inactive "●" +4 | mode-line.inactive "1:4" +4, mode-line.inactive "All" +4
view 1 320,0 320x464: "abc", scroll 0, selections 3..3, padding 8 8
status 1: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:4" +4, mode-line.secondary "All" +4
```

An eighteenth, `tests/headless/insert-word-delete/script`, runs on the
config in `tests/headless/insert-word-delete/config`, which binds no key
under `C-w`, so insert state keeps Vim's word delete there: after `i` and a
committed `hello world`, `C-w` leaves `hello `, still in insert state, and
the `l` pressed after it is text, `hello l`. Its output must be exactly
`tests/headless/insert-word-delete/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/insert-word-delete/config ../tests/headless/insert-word-delete/script
reload 1: installed, 1 chunks, 0 commands
key arrived: i KeyI -
key arrived: w KeyW control
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 4, theme "default"
view 0 0,0 640x464: "hello ", scroll 0, selections 6..6, padding 8 8
status 0: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:7" +4, mode-line.secondary "All" +4
key arrived: l KeyL -
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 6, theme "default"
view 0 0,0 640x464: "hello l", scroll 0, selections 7..7, padding 8 8
status 0: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "1:8" +4, mode-line.secondary "All" +4
```

A nineteenth, `tests/headless/display-rules/script`, runs on the config in
`tests/headless/display-rules/config`, which keeps the default layout,
binds `C-c n` to a command that makes a buffer called `notes` and displays
it (`BufferId.display`), and makes one display rule, whose target, the
right edge, the default layout lacks. The reload is installed, with a `rule:` line
for the rule left out, and the echo area says the same sentence after
`reload: `. `:ls` shows the buffer list in a new window at the end of the
tiled list, the stack, on the right, focused, while main keeps `scratch`,
the buffer being edited; `C-w h` then `C-c n` puts `notes` in another new
window below the list; and `:ls` again focuses the list's window, with the
list brought up to date, and makes no window. The views' ids skip the
minibuffer's, which the `:` prompt took. Its output must be exactly
`tests/headless/display-rules/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/display-rules/config ../tests/headless/display-rules/script
reload 1: installed, 1 chunks, 1 commands
rule: display rule 1 is left out: the layout has no right edge
scene 640x480, focused 0, echo "reload: display rule 1 is left out: the layout has no right edge", echo padding 8, preedit -, published 1, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: i KeyI -
key arrived: <Escape> Escape -
key arrived: : Semicolon shift
key arrived: <Enter> Enter -
scene 640x480, focused 3, echo "", echo padding 8, preedit -, published 10, theme "default"
view 0 0,0 320x464: "draft", scroll 0, selections 4..4, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4, mode-line.inactive "●" +4 | mode-line.inactive "1:5" +4, mode-line.inactive "All" +4
view 3 320,0 320x464: "  scratch\n", scroll 0, selections 0..0, padding 8 8
status 3: mode-line.state.normal "NORMAL" +8, mode-line.buffer "buffer-list" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: h KeyH -
key arrived: c KeyC control
key arrived: n KeyN -
scene 640x480, focused 4, echo "", echo padding 8, preedit -, published 15, theme "default"
view 0 0,0 320x464: "draft", scroll 0, selections 4..4, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4, mode-line.inactive "●" +4 | mode-line.inactive "1:5" +4, mode-line.inactive "All" +4
view 3 320,0 320x232: "  scratch\n", scroll 0, selections 0..0, padding 8 8
status 3 in mode-line.inactive: mode-line.inactive "buffer-list" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 4 320,232 320x232: "a note", scroll 0, selections 0..0, padding 8 8
status 4: mode-line.state.normal "NORMAL" +8, mode-line.buffer "notes" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: : Semicolon shift
key arrived: <Enter> Enter -
scene 640x480, focused 3, echo "", echo padding 8, preedit -, published 21, theme "default"
view 0 0,0 320x464: "draft", scroll 0, selections 4..4, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4, mode-line.inactive "●" +4 | mode-line.inactive "1:5" +4, mode-line.inactive "All" +4
view 3 320,0 320x232: "  notes\n  scratch\n", scroll 0, selections 18..18, padding 8 8
status 3: mode-line.state.normal "NORMAL" +8, mode-line.buffer "buffer-list" +4, mode-line.modified "●" +4 | mode-line.secondary "3:1" +4, mode-line.secondary "Bot" +4
view 4 320,232 320x232: "a note", scroll 0, selections 0..0, padding 8 8
status 4 in mode-line.inactive: mode-line.inactive "notes" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
```

A twentieth, `tests/headless/edge-sidebar/script`, runs on the config in
`tests/headless/edge-sidebar/config`, which chooses
`layout (.edge .left 25 Layout.default)`, sends the buffers of the minor
mode `notes` to the left edge with a display rule, and binds `C-c n` to a
command that makes such a buffer and displays it. The buffer is docked in
the left strip, 160 pixels of the 640, and main has the rest; `C-w l` and
`C-w h` move between them; `C-w H` moves the docked window back to the end
of the tiled list, where no window is docked and so no strip is kept, and
again docks it; `C-w m` makes it main; `C-w H` and `C-w C-c` dock and close
it, and the strip goes; and `C-w H` on the last tile is refused, with the
reason in the echo area. Its output must be exactly
`tests/headless/edge-sidebar/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/edge-sidebar/config ../tests/headless/edge-sidebar/script
reload 1: installed, 1 chunks, 1 commands
key arrived: c KeyC control
key arrived: n KeyN -
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 3, theme "default"
view 0 160,0 480x464: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 1 0,0 160x464: "a note", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "notes" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: l KeyL -
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 6, theme "default"
view 0 160,0 480x464: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 0,0 160x464: "a note", scroll 0, selections 0..0, padding 8 8
status 1 in mode-line.inactive: mode-line.inactive "notes" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
key arrived: w KeyW control
key arrived: h KeyH -
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 9, theme "default"
view 0 160,0 480x464: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 1 0,0 160x464: "a note", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "notes" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: H KeyH shift
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 12, theme "default"
view 0 0,0 320x464: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 1 320,0 320x464: "a note", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "notes" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: H KeyH shift
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 15, theme "default"
view 0 160,0 480x464: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 1 0,0 160x464: "a note", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "notes" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: m KeyM -
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 18, theme "default"
view 1 0,0 320x464: "a note", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "notes" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 0 320,0 320x464: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
key arrived: w KeyW control
key arrived: H KeyH shift
key arrived: w KeyW control
key arrived: c KeyC control
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 23, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: H KeyH shift
scene 640x480, focused 0, echo "window-edge-left: the last tiled window cannot leave the tiles", echo padding 8, preedit -, published 26, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
```

A twenty-first, `tests/headless/float-rule/script`, runs on the config in
`tests/headless/float-rule/config`, which keeps the default layout, binds
`C-c n` and `C-c m` to commands that each make a buffer and display it, and
sends what the first opens to a float and what the second opens to a float
`(pinned := true)` with two display rules. `C-c n` opens `notes` in a
float, view 1, centred in the tiled area at 60 by 50 percent, 384 by 232
at 128, 116, listed after view 0 and focused; `C-w C-p` focuses view 0,
and the float, transient, is gone; `C-c m` opens `memo` in a pinned float,
view 2, placed the same way, which stays when `C-w C-p` focuses view 0
again; and `C-w C-w` (the next window; plain `C-w w` is left for tabs)
reaches it, and `C-w F` moves it into the tiles, where it joins the stack
beside main. Its output must be exactly
`tests/headless/float-rule/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/float-rule/config ../tests/headless/float-rule/script
reload 1: installed, 1 chunks, 2 commands
key arrived: c KeyC control
key arrived: n KeyN -
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 3, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 1 128,116 384x232: "a note", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "notes" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: p KeyP control
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 6, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: c KeyC control
key arrived: m KeyM -
scene 640x480, focused 2, echo "", echo padding 8, preedit -, published 9, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 2 128,116 384x232: "a memo", scroll 0, selections 0..0, padding 8 8
status 2: mode-line.state.normal "NORMAL" +8, mode-line.buffer "memo" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: p KeyP control
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 12, theme "default"
view 0 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 2 128,116 384x232: "a memo", scroll 0, selections 0..0, padding 8 8
status 2 in mode-line.inactive: mode-line.inactive "memo" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
key arrived: w KeyW control
key arrived: w KeyW control
key arrived: w KeyW control
key arrived: F KeyF shift
scene 640x480, focused 2, echo "", echo padding 8, preedit -, published 17, theme "default"
view 0 0,0 320x464: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 2 320,0 320x464: "a memo", scroll 0, selections 0..0, padding 8 8
status 2: mode-line.state.normal "NORMAL" +8, mode-line.buffer "memo" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
```

A twenty-second, `tests/headless/float-anchor/script`, runs on the config
in `tests/headless/float-anchor/config`, which keeps the default layout,
binds `C-c f` to a command that puts eighty lines, `line00` to `line79`, at
the cursor, and `C-c h` to one that opens a buffer `hint` in a transient
float anchored at the cursor (`BufferId.float`), 50 percent of the tiled
area wide and 25 percent tall, without the focus. With the cursor on the
third row at its fifth column, the float is placed directly under the row,
at 40, 56: the padding of 8 and 4 cells of 8 across, the padding and two
rows of 16 down, and the row's 16. `C-f` scrolls the anchor's row out of
the view, and the float closes, the focus staying on view 0. With the
cursor on the last row the view shows, a new float has no room below the
row and is flipped above it, its bottom at the row's top, at 40, 308. Its
output must be exactly `tests/headless/float-anchor/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/float-anchor/config ../tests/headless/float-anchor/script
reload 1: installed, 1 chunks, 2 commands
key arrived: c KeyC control
key arrived: f KeyF -
key arrived: g KeyG -
key arrived: g KeyG -
key arrived: 2 Digit2 -
key arrived: j KeyJ -
key arrived: 4 Digit4 -
key arrived: l KeyL -
key arrived: c KeyC control
key arrived: h KeyH -
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 11, theme "default"
view 0 0,0 640x464: "line00\nline01\nline02\nline03\nline04\nline05\nline06\nline07\nline08\nline09\nline10\nline11\nline12\nline13\nline14\nline15\nline16\nline17\nline18\nline19\nline20\nline21\nline22\nline23\nline24\nline25\nline26\nline27\nline28\nline29\nline30\nline31\nline32\nline33\nline34\nline35\nline36\nline37\nline38\nline39\nline40\nline41\nline42\nline43\nline44\nline45\nline46\nline47\nline48\nline49\nline50\nline51\nline52\nline53\nline54\nline55\nline56\nline57\nline58\nline59\nline60\nline61\nline62\nline63\nline64\nline65\nline66\nline67\nline68\nline69\nline70\nline71\nline72\nline73\nline74\nline75\nline76\nline77\nline78\nline79", scroll 0, selections 18..18, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "3:5" +4, mode-line.secondary "3%" +4
view 1 40,56 320x116: "a hint", scroll 0, selections 0..0, padding 8 8
status 1 in mode-line.inactive: mode-line.inactive "hint" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
key arrived: f KeyF control
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 13, theme "default"
view 0 0,0 640x464: "line00\nline01\nline02\nline03\nline04\nline05\nline06\nline07\nline08\nline09\nline10\nline11\nline12\nline13\nline14\nline15\nline16\nline17\nline18\nline19\nline20\nline21\nline22\nline23\nline24\nline25\nline26\nline27\nline28\nline29\nline30\nline31\nline32\nline33\nline34\nline35\nline36\nline37\nline38\nline39\nline40\nline41\nline42\nline43\nline44\nline45\nline46\nline47\nline48\nline49\nline50\nline51\nline52\nline53\nline54\nline55\nline56\nline57\nline58\nline59\nline60\nline61\nline62\nline63\nline64\nline65\nline66\nline67\nline68\nline69\nline70\nline71\nline72\nline73\nline74\nline75\nline76\nline77\nline78\nline79", scroll 189, selections 207..207, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "30:5" +4, mode-line.secondary "37%" +4
key arrived: 2 Digit2 -
key arrived: 4 Digit4 -
key arrived: j KeyJ -
key arrived: c KeyC control
key arrived: h KeyH -
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 19, theme "default"
view 0 0,0 640x464: "line00\nline01\nline02\nline03\nline04\nline05\nline06\nline07\nline08\nline09\nline10\nline11\nline12\nline13\nline14\nline15\nline16\nline17\nline18\nline19\nline20\nline21\nline22\nline23\nline24\nline25\nline26\nline27\nline28\nline29\nline30\nline31\nline32\nline33\nline34\nline35\nline36\nline37\nline38\nline39\nline40\nline41\nline42\nline43\nline44\nline45\nline46\nline47\nline48\nline49\nline50\nline51\nline52\nline53\nline54\nline55\nline56\nline57\nline58\nline59\nline60\nline61\nline62\nline63\nline64\nline65\nline66\nline67\nline68\nline69\nline70\nline71\nline72\nline73\nline74\nline75\nline76\nline77\nline78\nline79", scroll 189, selections 375..375, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "54:5" +4, mode-line.secondary "67%" +4
view 2 40,308 320x116: "a hint", scroll 0, selections 0..0, padding 8 8
status 2 in mode-line.inactive: mode-line.inactive "hint" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
```

A twenty-third, `tests/headless/tabs/script`, runs on the config in
`tests/headless/tabs/config`, which keeps the default layout and binds
`tab-rename` to `C-c r` and `tab-move-right` to `C-c m`; every other tab
command is reached by the Vim scheme's own keys under `C-w`, tmux's. `C-w
s` splits view 0, with no tab bar for one tab. `C-w c` makes a second tab
and brings it into view: view 2 alone in a tiled area now 640 by 448, and
the tab bar's view last, view 3, in the strip above the bottom row, its
line `" 1 scratch   2 scratch "` with the second chip in
`tab-bar.selected`, no selection and no status field (`status 3: -`).
`C-w s C-w z` zooms the second tab on its new window, view 4 (the bar took
3). `C-w p` shows the first tab as it was left, views 0 and 1 side by side
and the focus on 1, with the first chip selected, and `C-w n` the second,
still zoomed. `C-w 3` is refused, `tab-select-3: there is no tab 3`.
`C-c r`, `notes` and `<Enter>` rename the second tab, `C-c m` on the last
tab moves nothing, and `C-w w`, `1` and `<Enter>` switch to the first.
`C-w &` closes it, leaving `notes` zoomed and no bar, and `C-w &` again is
refused, `tab-close: the last tab cannot be closed`. Its output must be
exactly `tests/headless/tabs/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/tabs/config ../tests/headless/tabs/script
reload 1: installed, 1 chunks, 0 commands
key arrived: w KeyW control
key arrived: s KeyS -
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 3, theme "default"
view 0 0,0 320x464: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 1 320,0 320x464: "", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: c KeyC -
scene 640x480, focused 2, echo "", echo padding 8, preedit -, published 6, theme "default"
view 2 0,0 640x448: "", scroll 0, selections 0..0, padding 8 8
status 2: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 3 0,448 640x16: " 1 scratch   2 scratch ", scroll 0, selections , padding 8 0
decorations 3: tab-bar 0..11 tab-bar.selected 12..23
status 3: -
key arrived: w KeyW control
key arrived: s KeyS -
key arrived: w KeyW control
key arrived: z KeyZ -
scene 640x480, focused 4, echo "", echo padding 8, preedit -, published 11, theme "default"
view 4 0,0 640x448: "", scroll 0, selections 0..0, padding 8 8
status 4: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 3 0,448 640x16: " 1 scratch   2 scratch ", scroll 0, selections , padding 8 0
decorations 3: tab-bar 0..11 tab-bar.selected 12..23
status 3: -
key arrived: w KeyW control
key arrived: p KeyP -
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 14, theme "default"
view 0 0,0 320x448: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 1 320,0 320x448: "", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 3 0,448 640x16: " 1 scratch   2 scratch ", scroll 0, selections , padding 8 0
decorations 3: tab-bar.selected 0..11 tab-bar 12..23
status 3: -
key arrived: w KeyW control
key arrived: n KeyN -
scene 640x480, focused 4, echo "", echo padding 8, preedit -, published 17, theme "default"
view 4 0,0 640x448: "", scroll 0, selections 0..0, padding 8 8
status 4: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 3 0,448 640x16: " 1 scratch   2 scratch ", scroll 0, selections , padding 8 0
decorations 3: tab-bar 0..11 tab-bar.selected 12..23
status 3: -
key arrived: w KeyW control
key arrived: 3 Digit3 -
scene 640x480, focused 4, echo "tab-select-3: there is no tab 3", echo padding 8, preedit -, published 20, theme "default"
view 4 0,0 640x448: "", scroll 0, selections 0..0, padding 8 8
status 4: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 3 0,448 640x16: " 1 scratch   2 scratch ", scroll 0, selections , padding 8 0
decorations 3: tab-bar 0..11 tab-bar.selected 12..23
status 3: -
key arrived: c KeyC control
key arrived: r KeyR -
key arrived: <Enter> Enter -
scene 640x480, focused 4, echo "", echo padding 8, preedit -, published 26, theme "default"
view 4 0,0 640x448: "", scroll 0, selections 0..0, padding 8 8
status 4: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 3 0,448 640x16: " 1 scratch   2 notes ", scroll 0, selections , padding 8 0
decorations 3: tab-bar 0..11 tab-bar.selected 12..21
status 3: -
key arrived: c KeyC control
key arrived: m KeyM -
scene 640x480, focused 4, echo "", echo padding 8, preedit -, published 29, theme "default"
view 4 0,0 640x448: "", scroll 0, selections 0..0, padding 8 8
status 4: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 3 0,448 640x16: " 1 scratch   2 notes ", scroll 0, selections , padding 8 0
decorations 3: tab-bar 0..11 tab-bar.selected 12..21
status 3: -
key arrived: w KeyW control
key arrived: w KeyW -
key arrived: <Enter> Enter -
scene 640x480, focused 1, echo "", echo padding 8, preedit -, published 35, theme "default"
view 0 0,0 320x448: "", scroll 0, selections 0..0, padding 8 8
status 0 in mode-line.inactive: mode-line.inactive "scratch" +4 | mode-line.inactive "1:1" +4, mode-line.inactive "All" +4
view 1 320,0 320x448: "", scroll 0, selections 0..0, padding 8 8
status 1: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 3 0,448 640x16: " 1 scratch   2 notes ", scroll 0, selections , padding 8 0
decorations 3: tab-bar.selected 0..11 tab-bar 12..21
status 3: -
key arrived: w KeyW control
key arrived: & Digit7 shift
scene 640x480, focused 4, echo "", echo padding 8, preedit -, published 38, theme "default"
view 4 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 4: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
key arrived: w KeyW control
key arrived: & Digit7 shift
scene 640x480, focused 4, echo "tab-close: the last tab cannot be closed", echo padding 8, preedit -, published 41, theme "default"
view 4 0,0 640x464: "", scroll 0, selections 0..0, padding 8 8
status 4: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
```

A twenty-fourth, `tests/headless/at-point/script`, shows completion at
point's auto popup on the shared config (`tests/headless/config`), under
the Vim scheme that ships: in insert state it commits `alpha alpine beta`,
breaks the line with `RET`, types `a` and `l`, each re-arming the pause of
the shipped `words` source, and settles; then `advance 240` fires the pause,
`join` waits for the `words` job, and the scene lists the words of the open
buffers that match `al`, nothing chosen, in the candidate list's view above
the bottom row, the window shorter by its two rows. `C-n` chooses the first
and previews it in the buffer's text; `RET` accepts it, and the list is
gone and the window full height again. Its output must be exactly
`tests/headless/at-point/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/at-point/script
reload 1: installed, 2 chunks, 1 commands
key arrived: i KeyI -
key arrived: <Enter> Enter -
key arrived: a KeyA -
key arrived: l KeyL -
job 1 words: started
job 1 words: ok
job 1 words: ok
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 11, theme "default"
view 0 0,0 640x432: "alpha alpine beta\nal", scroll 0, selections 20..20, padding 8 8
status 0: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "2:3" +4, mode-line.secondary "Bot" +4
view 1 0,432 640x32: "alpha\nalpine", scroll 0, selections , padding 8 0
decorations 1: minibuffer.candidate 0..5 minibuffer.match 0..2 minibuffer.candidate 6..12 minibuffer.match 6..8
status 1: -
key arrived: n KeyN control
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 13, theme "default"
view 0 0,0 640x432: "alpha alpine beta\nalpha", scroll 0, selections 23..23, padding 8 8
status 0: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "2:6" +4, mode-line.secondary "Bot" +4
view 1 0,432 640x32: "alpha\nalpine", scroll 0, selections , padding 8 0
decorations 1: minibuffer.chosen 0..5 minibuffer.match 0..2 minibuffer.candidate 6..12 minibuffer.match 6..8
status 1: -
key arrived: <Enter> Enter -
scene 640x480, focused 0, echo "", echo padding 8, preedit -, published 15, theme "default"
view 0 0,0 640x464: "alpha alpine beta\nalpha", scroll 0, selections 23..23, padding 8 8
status 0: mode-line.state.insert "INSERT" +8, mode-line.buffer "scratch" +4, mode-line.modified "●" +4 | mode-line.secondary "2:6" +4, mode-line.secondary "Bot" +4
```

Two more runs of the gate are on a real file, and so on a script that
cannot be checked in whole: the file port takes absolute paths only. Each
is one entry of the `ffi-test` task, a shell of its own that makes a
temporary directory with `mktemp -d`, removes it by a trap when the shell
ends, copies `tests/headless/ex/note.txt` into it, and writes the script
there from a checked-in template in which `@FILE@` stands for the copy's
path. The run must exit with status 0, the copy must then hold the bytes
of `tests/headless/ex/note-expected`, and no line of the output may start
with `commands:`, which the `show` line at the end of each script would
print if the editor had not quit before it.

- `tests/headless/ex/save-quit-script`: `e` and the path, `join`, `i`, a
  committed text, `<Escape>`, `w`, `join`, `q`, and then `show`.
- `tests/headless/ex/wq-script`: the same with `wq` in place of `w`, the
  `join` and `q`, and a `join` after it, and then `show`.

**An evil session on a file** is a third process check of the same form
(`tests/headless/session/`): the entry copies `verse.txt` into its
temporary directory and writes the template `script` there. The script
loads no config. It opens the file with the `:` key and `e`, and then
runs, by keys, `2dw`, `.`, `u`, `j`, `cw`, the typed text `new`,
`<Escape>`, `w`, `.`, `v`, `e`, `y`, `$`, `p`, `u`, `C-r`, and `:w`,
with a `scene` line after each step. The run must exit with status 0. Its
output, with the temporary directory's path written `@DIR@`, must be
exactly `tests/headless/session/expected`: each scene's text, its
selection (`26..32` while the visual selection is open, one offset twice
otherwise), the state's badge in the status line (`NORMAL`, `INSERT`,
`VISUAL`), the cursor's line:col and position, and the echo, which is empty until the save says
`wrote @DIR@/verse.txt`. And the copy must hold the bytes of
`tests/headless/session/verse-expected`.

**`open-file`'s prompt over real files** is a process check of the same
form (`tests/headless/open-file/`): the entry copies the tree `tree/`
(`alpha.txt`, `beta.txt`, `.hidden` and `notes/todo.md`) into its
temporary directory and writes the template `script` there with that
directory's path in place of `@DIR@`. The script loads no config. It runs
`open-file` and joins: the prompt starts with the executable's working
directory and lists it, which is never printed. `C-u` deletes the input,
and the tree's directory is committed and listed: `notes/`, annotated
`directory`, then `alpha.txt` and `beta.txt`, and not `.hidden`. A `.`
lists `.hidden` among the names that hold a `.`, in the library's order,
with no new job line: the directory was read once. `<Backspace>` deletes
it, `no` lists `notes/` with its match, `<Tab>` puts `notes/` in the input
and the directory is listed, `todo.md`, and `C-n` and `<Enter>` open it.
Then `open-file` again, `C-u`, and a directory that is not there: the echo
area says `files: cannot list @DIR@/tree/missing/: nothing is at the
path`, and nothing is listed. Every job is waited for with `join`, so its
lines are fixed. The run must exit with status 0, and its output, with the
temporary directory's path written `@DIR@`, must be exactly
`tests/headless/open-file/expected`:

```console
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config "$dir/script"
run open-file: ok
job 1 files: started
job 1 files: ok
job 1 files: ok
key arrived: u KeyU control
job 2 files: started
job 2 files: ok
job 2 files: ok
job 3 files: started
job 3 files: ok
job 3 files: ok
scene 0x0, focused 1, echo "", echo padding 8, preedit -, published 12, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 0,0 0x0: "@DIR@/tree/", scroll 0, selections 69..69, padding 8 0
status 1: minibuffer.prompt "Open file: "
view 2 0,0 0x0: "notes/     directory\nalpha.txt\nbeta.txt", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..20 minibuffer.annotation 11..20 minibuffer.candidate 21..30 minibuffer.candidate 31..39
status 2: -
scene 0x0, focused 1, echo "", echo padding 8, preedit -, published 14, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 0,0 0x0: "@DIR@/tree/.", scroll 0, selections 70..70, padding 8 0
status 1: minibuffer.prompt "Open file: "
view 2 0,0 0x0: ".hidden\nalpha.txt\nbeta.txt", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..7 minibuffer.match 0..1 minibuffer.candidate 8..17 minibuffer.match 13..14 minibuffer.candidate 18..26 minibuffer.match 22..23
status 2: -
key arrived: <Backspace> Backspace -
scene 0x0, focused 1, echo "", echo padding 8, preedit -, published 17, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 0,0 0x0: "@DIR@/tree/no", scroll 0, selections 71..71, padding 8 0
status 1: minibuffer.prompt "Open file: "
view 2 0,0 0x0: "notes/  directory", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..17 minibuffer.match 0..2 minibuffer.annotation 8..17
status 2: -
key arrived: <Tab> Tab -
job 4 files: started
job 4 files: ok
job 4 files: ok
scene 0x0, focused 1, echo "", echo padding 8, preedit -, published 22, theme "default"
view 0 0,0 0x0: "", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 1 0,0 0x0: "@DIR@/tree/notes/", scroll 0, selections 75..75, padding 8 0
status 1: minibuffer.prompt "Open file: "
view 2 0,0 0x0: "todo.md", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..7
status 2: -
key arrived: n KeyN control
key arrived: <Enter> Enter -
job 5 load-file: started
job 5 load-file: ok
job 6 find-workspace: started
job 6 find-workspace: ok
job 7 find-mode-markers: started
job 7 find-mode-markers: ok
scene 0x0, focused 0, echo "", echo padding 8, preedit -, published 31, theme "default"
view 0 0,0 0x0: "todo: list the files\n", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "todo.md" +4, mode-line.secondary "@DIR@/tree/notes" +4 | mode-line.secondary "code" +4, mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
run open-file: ok
job 8 files: started
job 8 files: ok
job 8 files: ok
key arrived: u KeyU control
job 9 files: started
job 9 files: ok
job 9 files: ok
job 10 files: started
job 10 files: ok
scene 0x0, focused 3, echo "files: cannot list @DIR@/tree/missing/: nothing is at the path", echo padding 8, preedit -, published 43, theme "default"
view 0 0,0 0x0: "todo: list the files\n", scroll 0, selections 0..0, padding 8 8
status 0: mode-line.state.normal "NORMAL" +8, mode-line.buffer "todo.md" +4, mode-line.secondary "@DIR@/tree/notes" +4 | mode-line.secondary "code" +4, mode-line.secondary "1:1" +4, mode-line.secondary "All" +4
view 3 0,0 0x0: "@DIR@/tree/missing/", scroll 0, selections 77..77, padding 8 0
status 3: minibuffer.prompt "Open file: "
view 2 0,0 0x0: "", scroll 0, selections , padding 8 0
status 2: -
key arrived: <Escape> Escape -
```

**A view that follows its cursor** is a fourth process check of the same
form (`tests/headless/view/`): the entry copies `lines.txt`, 120 lines
`000` to `119`, into its temporary directory and writes the template
`script` there. The script loads no config. It begins with
`resize 640 480`, opens the file with the `:` key and `e`, and then, with
a `scene` line after each step, runs `100j`, `C-u`, `C-f` twice, `z t`,
`z b`, and `resize 640 160`. The run must exit with status 0, and its
output, with the temporary directory's path written `@DIR@`, must be
exactly `tests/headless/view/expected`. Each `view` line prints the scroll
anchor's byte offset and the cursor's: line n of the file starts at byte
4n, so `scroll 284, selections 400..400` after `100j` is a view whose
first row is line 71 and whose cursor is on line 100, the last of its 30
rows. The script's comments say what each step's numbers are and why
([the gate](the-gate.md) has them in one table).

**`j` and `k` aiming for a display column** is a fifth process check of
the same form (`tests/headless/column/`): the entry copies `lines.txt`,
three lines of which one has a tab and one a wide character, and writes
the template `script` there. The script loads no config and has no
`resize`, so the frame stays 0 by 0. It opens the file and, with a `scene`
line after each step, runs `l l j`, `k` and `G l k`. The run must exit
with status 0, and its output, with the temporary directory's path written
`@DIR@`, must be exactly `tests/headless/column/expected`: the cursor at
bytes 12, 2 and 6 ([the gate](the-gate.md) says which characters those
are).

**A script waits where a command starts a job.** A script's lines are
posted to the editor without waiting, and a job's result is queued when
the job ends, so what the script has after a line that starts a job is
handled before the job's result unless the script waits:

- **After `e`.** The open is a job. Without a `join` the committed text
  goes into the scratch buffer, `w` says that buffer has no file, `q`
  still quits with status 0, and the file is as it was.
- **Between `w` and `q`**, the `join` only puts the host's lines in one
  order. Either order writes the file and quits: `q` waits for a save in
  flight.
- **After `wq`.** The quit `wq` asks for waits for the save, so the loop
  is still running when the accept key has been handled. Without a `join`
  the `show` line is handled while the save runs and prints a `commands:`
  line, and the end of the script stops the loop, which cancels its jobs,
  the save among them: the file is then left unwritten, or written, by
  timing. With the `join`, the wait ends when the delivery of the save's
  result has ended the loop; the script is read no further, and its end
  stops nothing. The same holds for a `q` typed while a save is in
  flight.

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
shows that the reload and the job were each followed by one. A command
that quits the editor (`quit`, `save-and-quit`) ends the loop once no
buffer that holds a file has unsaved changes and no save is in flight, and
a window's close request is a quit by the same rule: while a buffer that
holds a file has unsaved changes it is refused, with `quit: <name> has
unsaved changes` in the echo area, and the loop goes on. The editor then cancels the jobs that
are left and prints nothing more, and the lines of the script after the
quit are not run: a `settle` or a `join` that was waiting ends at once,
and is no failure.

A key press is stepped through the scheme. Config's bindings are looked up
first, then the scheme's own keymaps, which are those of the view's Vim
state. Every default key runs a command the editor ships: the motions,
the operators, `x p P o O`, `u`, `C-r`, `.`, `i a I A`, `v V`,
`<Escape>`, `:`, typed text and the minibuffer's two keys. A
command a key runs prints nothing: what became of it is
in the next scene's echo area, `<name>: no such command`,
`<name>: refused: <error>`, `<name>: interrupted`, or `<name>: <reason>`
for a command that gave up or broke off, and a command that was
refused or interrupted, or that gave up, is rolled back: its buffer's text and selections are
as they were before it. A command that broke off is not rolled back: what
it did stays, and the key that ran it has entered no state (an operator
whose motion failed after it moved leaves the cursor where the motion got
to). `C-g` is the interrupt key: it stops a command that
is running at its next request to the editor, and is then looked up like
any other key; under the Vim scheme it runs `keyboard-quit`, which cancels
a running `:!` or says `Quit`. A command that takes longer than 100 ms is logged on stderr,
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
theme: no theme is registered as `<name>`
segment: no segment is registered as `<name>`
style: no completion style is registered under `<name>`
rule: display rule <n> is left out: <reason>
run <name>: ok            (or "refused: <error>", "interrupted",
                           "gave up: <reason>", "broke off: <reason>",
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
scene <w>x<h>, focused <id or ->, echo <quoted>, echo padding <n>, preedit <quoted or ->, published <n>, theme <quoted name>
view <id> <x>,<y> <w>x<h>: <quoted text>, scroll <offset>, selections <anchor>..<head> …, padding <across> <down>[ top <n>]
status <view id>[ in <status face>]: <face> <quoted text>[ +<padding>], … | <face> <quoted text>[ +<padding>], …   (or "-" for no field)
scene: none
loop: refused: <error>
```

`scene` prints the frame's size, the focused view (`-` while the frame does
not have the keyboard focus), the echo area and its padding in points (the
bottom row's inset: the frame padding, and at least the window's corner
clearance outside fullscreen, which the headless window says is 0), the
input method's preedit
(`-` when there is none), how many scenes have been published and the name
of the theme the scene was drawn in (`default` until a config names another
or `load-theme` loads one); then, for
each view in drawing order, its rectangle, the text of its snapshot, read
from the library, the offsets of its scroll anchor and of each range of
its selection, and its padding across and down in points: the frame
padding both ways for a window (config's `framePadding`, or the editor's 8),
and for the minibuffer's view the bottom row's inset across and none down.
A window along the frame's top edge is padded further at the top by what a
window's title bar covers of it, printed as ` top <n>` after the padding
when it is not 0; the driver's `resize` says no title bar, so no line of
the headless mode prints one.
After each view's line comes its status line, one entry a
field, each the field's face, its text and, when it has one, its padding
in points after `+`: the left fields, then ` | ` and the right fields when
there are any. A view with a status face prints it after its id, as `in
mode-line.inactive` for a window that is not selected. Under the default
mode line (`Editor/ModeLine.lean`) the left side is the badge of the
view's Vim state (`NORMAL` in `mode-line.state.normal`), the buffer's name
in `mode-line.buffer`, while the buffer is modified `●` in
`mode-line.modified`, while a check has found its file changed on disk
`[changed on disk]` in `mode-line.changed`, and the directory its file was
opened in; the right
side its major mode, the cursor's line:col and its position, each in
`mode-line.secondary`. A segment with nothing to say has no field: a
buffer that is not modified has no mark, and the scratch buffer no
directory. This is how a script sees a view's state, its buffer's name,
whether the buffer is modified and where its cursor is. A temporary
directory's path in the directory field is written `@DIR@` by the gate's
`sed`, as it is everywhere else.
`scene: none` means no scene has been published: the loop has not been
needed yet.

A reload whose config names a theme nobody registered is installed, and
its report's lines end with `theme: no theme is registered as `<name>``;
the echo area says ``reload: no theme is registered as `<name>` ``. A
reload whose config lists a segment nobody registered (`modeLine`) is
installed too, the segment left out: its report has a line
``segment: no segment is registered as `<name>` `` for each, after the
theme's, and the echo area says each sentence after `reload: `, joined by
`; ` (`tests/headless/mode-line`). A reload whose config chooses a
completion style nobody registered (`useStyle`, `useStyleFor`) is
installed too, its category left to the default style and the default to
`fuzzy`: its report has a line
``style: no completion style is registered under `<name>` `` for each,
after the segments', and the echo area says each sentence after the
segments'. A reload whose config makes a display
rule whose target does not exist under the layout it chose (`displayRule`)
is installed too, the rule left out: its report has a line
`rule: display rule <n> is left out: <reason>` for each, `<n>` its place
in the `setup` from 1, after the styles', and the echo area says each
sentence after the styles' (`tests/headless/display-rules`).

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
its jobs still running. The exit status is 0 when the script ran to its end
or a command quit the editor before it,
1 when it could not, and 2 for a command line it does not understand. With
status 1 a line on stderr says why: the script cannot be read; with
`--render`, the render session could not be started, with the library's
reason (the system refused its render thread); a `settle`, named by its
line, ran out with a reload still running (a chunk or `setup` is slow or
does not end); a `join`, named by its line, ran out with a job still
running; or the editor thread did not answer.
