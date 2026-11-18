import ConfigTest.Bench
import ConfigTest.Check
import ConfigTest.Editor.AtPoint
import ConfigTest.Editor.Config.Directory
import ConfigTest.Editor.Config.Elaborate
import ConfigTest.Editor.Evil
import ConfigTest.Editor.Evil.TreeObjects
import ConfigTest.Editor.Ex
import ConfigTest.Editor.Face
import ConfigTest.Editor.Files
import ConfigTest.Editor.Headless
import ConfigTest.Editor.Indent
import ConfigTest.Editor.Loop
import ConfigTest.Editor.Minibuffer
import ConfigTest.Editor.Themes
import ConfigTest.Editor.Themes.Check
import ConfigTest.Editor.VersionControl.Gutter
import Editor.ExecuteCommand.Compiled

/-!
# Checks of the config session against the real elaborator

The `config-test` executable is linked exactly like `editor`, with the glue
object, the Rust archive and Lean's elaborator. `mise run ffi-test` runs it
as `config-test <sysroot> <olean dir> <syntax fixtures> <default config>`:
the Lean toolchain's directory, the directory holding the package's
`.olean` files, the directory of the syntax fixtures (`tests/syntax`), whose
Rust indent fixture the indent checks read, and the directory of the
default config `mise run install` ships (`config/default`), which
`defaultConfigChecks` read. It reads nothing from the
environment or the working directory. It runs every check in `checks`, names
the ones that failed, and exits non-zero if any did.

The checks themselves live in test modules that mirror the module they
test, where ModelTest keeps the model counterpart where there is one: the
checks of the headless host's own loop, threads and scripts are in
`ConfigTest/Editor/Headless.lean` (`ConfigTest.Editor.Headless`), and those
of prompts through the host in `ConfigTest/Editor/Minibuffer.lean`. A test
module keeps the helpers only its checks use. Helpers that several test
modules use are in small support modules under `ConfigTest/Support/`, each
of one kind of fixture, and `ConfigTest.Check` holds the `Check` type, the
`Context` every check is given, `failures`, `run` (handed `checks` by
`main`) and `usage`. Everything is in the namespace `ConfigTest`, so a list
is `ConfigTest.<name>Checks` whichever module holds it. This module keeps
only `checks`, which runs them in order, and `main`.

The model tests (`ModelTest.lean` and `ModelTest/`) pin the decisions of the
config session on fakes. The checks here pin what only real collaborators can
show:

- `elaboratorChecks`: the real elaborator behaves as the fake of its port
  assumes, and compiled code and config share state;
- `directoryChecks`: the directory source, each check in a temporary
  directory of its own;
- `hostChecks`: the phase's acceptance tests through the headless host, with
  the real elaborator, the real queue and the real text binding, asserted on
  the lines the host prints;
- `threadChecks`: the editor answers events while a chunk elaborates, reloads
  are serialised, and a replaced config is not retained;
- `jobChecks`: jobs from config through the host: a handler receives a job's
  result on the editor thread, a reload that installs cancels the old
  config's jobs and a rejected one does not, and how each ending of a job is
  reported;
- `shippedChecks`: what the executable's hosts are handed as compiled code
  (`Headless.shippedOver`): the registry they start with binds `C-s-f` to
  `toggle-fullscreen`, `s-m` to `minimise-window` and `s-q` to `quit`, all
  compiled, and registers the buffer commands with the ex names `b`, `ls`
  and `bd` bound to them, and the completion sources that ship;
- `scriptChecks`: the headless mode's script and its driver, and the editor
  loop through the host: a commit and the scene it prints, read from the
  library, a scene published after a reload's install and a job's command
  once the frame exists, the scene whose echo is the refusal once a command
  has released the focused buffer's text, the line the host prints for a
  program of the loop that is refused, and a window's close request with
  nothing unsaved ending the loop;
- `dispatchChecks`: keys through the host, with the test scheme and
  compiled commands and bindings written here: a compiled binding runs its
  command, a command that fails is rolled back and says so, the interrupt
  key stops a command that loops and stops nothing when none runs, config's
  command of a compiled command's name runs until a reload drops it, a
  reload rebinds a key, compiled bindings run when config fails to load,
  a command slower than the threshold is logged, on the fake clock, and a
  marked interrupt key no loop takes, one that cannot be read or one that
  arrives when the frame cannot be made, still has the flag lowered for it.
  Those last two run no loop: each pulls the key off the queue and hands it
  to the host's handler on its own thread (`withRunning`);
- `modeChecks`: modes through the host, with the test scheme: a role's key
  runs the command of a mode config defines, a store command among them,
  in a view of a buffer that has the mode, and once a reload drops the mode
  it runs the global binding; and a role's key runs the command of a mode
  compiled code hands the host (`Compiled.modes`), before any reload and
  after a reload of a config that defines none. The host's frame is made
  with the scratch buffer's major mode set (`Compiled.major`), since no
  command can set one yet, and the key pressed is the test scheme's for the
  role (`Session.pressKeys`), so no check names a scheme's key;
- `promptChecks`: prompts through the host, with the test scheme, the
  minibuffer's commands and its mode as compiled code hands them
  (`Minibuffer.commands`, `Minibuffer.modes`) and commands written here: a
  command asks, a commit is typed into the minibuffer and the scene shows
  it; the accept key runs the continuation's command with the answer and
  the cancel key does not; a job's result is delivered while a prompt is
  open, on the fake clock; the continuation is looked up when the answer
  arrives, across a reload; the answer's command runs before the next key;
  and it is looked up after the accepting command's write to a store was
  written back; a prompt lists the candidates of a source config registers
  and asks for by name, and of one the executable's hosts ship
  (`Headless.shippedOver`), which config's source of its name replaces
  until a reload drops it; and completion phase 4's criteria: the list
  drawn in a view of its own up to the rows config's display sets, the
  height it takes given back when the prompt closes, an annotation's
  column and the matched ranges' face, and a display config chooses for
  one category, redrawn with the default by the install's own scene once a
  reload drops the choice. The accept key and the cancel key are the test scheme's
  for the roles the minibuffer's mode fills;
- `exChecks`: the ex command line through the host, with the test scheme
  and the ex line's commands and the ex names that ship as compiled code
  hands them (`Ex.commands`, `Ex.bindings`): the ex line `reload` reloads
  the config with no restart, so a key config rebound runs the other
  command; an ex name config binds runs config's command, and is unknown
  after a reload without it; config's binding of a shipped name runs in
  its place until a reload drops it; and a name nobody bound is said in
  the scene's echo, with the editor going on. Each line is committed into
  the minibuffer and accepted with the test scheme's key for the role the
  minibuffer's mode fills;
- `exScriptChecks`: scripts that a command ends, with `Headless.run` on
  scripts built here, over the library's file service, so they run after
  `fileChecks` and share their table of waits and pump: `e` on a file in a
  temporary directory, a commit, `w`, a join and `q`, and the same with
  `wq` and a join after it, each leave the file holding the buffer's text
  and end the script with no failure and the `show` line after the quit
  not run; a `q` that is refused leaves the script running; and a wait on
  a host whose loop a command ended answers `ended`. They are apart from
  `scriptChecks`, which are defined before what these hosts are handed;
- `leaderChecks`: the leader through a host of the Vim scheme that ships:
  a config's `<leader> f f` binding runs on `SPC f f` while config sets no
  leader, on `\ f f` once a reload sets the leader to `\` (and `SPC f f`
  then does not run it), and `SPC` typed in insert state is a space while
  `SPC f f` after `<Escape>` runs the binding;
- `hintChecks`: the key hints through a host of the Vim scheme that ships:
  after a reload, a config's prefix name and a binding's description are
  in the scene's `hint` lines after `SPC` and after `SPC f`, none are after
  the binding runs, and a reload that drops the prefix name lists the
  prefix unnamed (with a delay of 0, so they are shown at once);
- `keyHintChecks`: when and where the key hints are shown, through a host
  of the Vim scheme that ships, on the fake clock and the recorder: after
  `SPC` and the default delay the scene lists the keys that can follow
  with their descriptions and prefix names, drawn by the minibuffer
  display above the bottom row, and none before; a sequence completed or
  reset before the delay withdraws it and shows none; a delay of 0 shows
  them in the first scene; the pending keys are drawn in the selected
  window's status line while pending and cleared once the sequence
  completes; a display config chooses for `key` draws them; `.never` arms
  nothing; a reload while `SPC` is pending that sets `.never` closes hints
  shown and withdraws a wait, one that keeps the delay keeps its wait,
  and one that sets it again arms a new wait; and a reload refuses a delay
  over a minute, one that is not a delay and one set twice;
- `defaultConfigChecks`: the default config `mise run install` ships, read
  from the directory the fourth argument names: a reload of it through a
  host of the Vim scheme that ships installs with no diagnostic and
  `SPC f f` then asks for a path to open; each of its bindings names a
  registered command; and each prefix it binds under the leader has a
  prefix name (`Registry.prefixName?`);
- `indentChecks`: `=` and the indented new lines through a host of the Vim
  scheme that ships, over the library's Rust grammar: `gg=G` on the
  mangled Rust indent fixture (`tests/syntax/rust/indent.rs`, read from the
  directory the third argument names) gives the fixture back, `=af`
  re-indents one function, one `u` undoes it and `.` repeats it, rows
  inside a string and a comment keep their indent, `RET` after an opening
  brace and `o`/`O` in a body start at the tree's level, and a buffer with
  no language or no indents query is as before;
- `evilChecks`: evil from config through the host, with the test scheme:
  a config that the real elaborator loads names the vocabulary the editor
  ships (`Evil.motions`) and hands it to evil's move command, as it is and
  with a motion of config's own added. It shows what `Editor.lean` lets
  config name; where a motion of the editor's leads is not said here;
- `reloadEchoChecks`: a rejected reload's first error is said in the echo
  area, while the old config runs; a reload that installs says nothing;
  and one rejected before the frame is made is said once it is;
- `faceChecks`: a face set in a config file reaches the next frame,
  through a host handed the display's real binding over the library's
  layout: the host's reload re-themes its display (`Config.retheme`), and
  the frame the library made of the next scene is compared with a second
  display's frame of the same scene in a theme written here; and a reload
  that makes `mode-line` taller sizes the next scene by the new heights,
  which `agree`, asked with no event between, shows;
- `cursorResolutionChecks`: the completeness check's model of a cursor's
  colours (`Themes.effective`) is the real layout's: for every shipped
  theme, and two whose cursor sets one colour alone, each cursor face's
  frame is the frame of a mirror theme that sets the modelled colours;
- `themeChecks`: named themes through a host over the display's real
  binding: `load-theme` switches the frame to the chosen theme with config's
  face over it, with no reload, and the scene line names the theme; and a
  config naming a theme nobody registered says so in the echo area;
- `fileChecks`: files through the host, over the library's file service.
  They are the checks whose hosts are over a real service, so they share
  one table of waits and the one completion pump, which the first of them
  starts, and they run last. Each has temporary directories of its own and
  writes its files' bytes itself.
  - A job from config loads a file, and its handler makes a text of it:
    the file's path is written into the config it loads.
  - The file commands and their jobs as compiled code registers them
    (`Files.commands`, `Files.jobs`): opening a file shows a buffer of its
    text, named by its base name; saving a modified buffer writes the
    buffer's text and clears the status line's modified field; opening a
    path that is open starts no load; open then save with no edit leaves
    the bytes of an LF file and of a CRLF file as they were, with the save
    seen to have written; a save of a file changed on disk leaves it and
    says so; and opening a path with no file says so and leaves the
    window. The driver's `run` hands a command no argument, so each host
    is handed a command, written here, that runs the compiled open command
    with a path (`opening`). The last runs the open command by its name,
    with no path: it asks for one, the path is committed into the
    minibuffer, and the accept key opens it. Each host is handed the
    minibuffer's commands and its mode for that.

A check controls time through a port, never by sleeping and hoping: a
decorator of the elaborator port (`Gate`) holds one chunk's elaboration open
until the check lets it go, and a host's jobs wait on a fake clock
(`Editor/Job/Fake.lean`) that only the check moves. Every wait is a poll with
a bound, so broken code fails a check within seconds instead of hanging the
executable. Each line a host emits is recorded with the thread that emitted
it, which is how a check sees that a handler ran on the editor thread.

All the checks share one import of the base, made once in `run`: a second
import in one process about doubles its memory. Hosts follow one another on
the process's one editor queue and never overlap: every check stops its host
before it returns.

No check makes the process abort. In particular none evaluates a declaration
that reads an `initialize`d constant of config's, and none runs config that
recurses without bound.

The executable also holds the benchmark (`ConfigTest.Bench`,
`ConfigTest/Bench.lean`), which the gate builds and never runs.
-/

namespace ConfigTest

open Editor

/-- What compiled code hands the hosts of the command prompt's checks: the
minibuffer's commands and its mode, the command prompt, the binding search
and the command that loads a theme, and the themes that ship. -/
def commandCompiled : Compiled :=
  { minibufferCompiled with
    commands :=
      Minibuffer.commands ++ ExecuteCommand.commands ++ BindingSearch.commands ++ Themes.commands
    themes := Themes.shipped }

/-- A chunk whose `setup` defines the style `starts`, which keeps the
candidates a text starts, in their order, chooses it for the categories
`command` and `binding`, registers `zz-other`, which says `other`, bound to
`SPC f f` with no description, `yy-said`, which says `said`, bound to
`SPC y y` and described `Say it`, and, when `mine`, `zz-mine`, which says
`mine`. -/
def commandChunk (mine : Bool) : String :=
  "def setup : SetupM Unit := do\n" ++
    "  defineStyle (.keeping \"starts\" fun text candidate => candidate.startsWith text)\n" ++
    "  useStyleFor \"command\" \"starts\"\n" ++
    "  useStyleFor \"binding\" \"starts\"\n" ++
    "  command \"zz-other\" (message \"other\")\n" ++
    "  command \"yy-said\" (message \"said\")\n" ++
    "  bindKey \"SPC y y\" \"yy-said\" (desc := \"Say it\")\n" ++
    "  bindKey \"SPC f f\" \"zz-other\"\n" ++
    if mine then "  command \"zz-mine\" (message \"mine\")\n" else ""

/-- The checks of the command prompt (`Editor/ExecuteCommand.lean`) through
a host over the real elaborator and the real registry: its candidates are
the commands compiled code registers and config's, and a reload that drops
one of config's drops it from them, and the command it runs is a step of
its own, so `load-theme` asked through it puts the chosen theme in force
with no key bound to either; a command config binds is shown with its keys.
And of the binding search (`Editor/BindingSearch.lean`) in the same session:
it lists a binding of config's with its keys and description, and accepting
it runs its command. The style `starts`, which config chooses for the
categories `command` and `binding`, keeps each listing short and in the
source's order, so no check pins the library matcher's order. -/
def commandPromptChecks (context : Context) : List Check :=
  [{  name :=
        "criteria 1, 2 and 3: the command prompt lists the commands compiled code registers and config's, config's in the order registered; a reload whose config no longer registers zz-mine drops it from the candidates; from a config that binds neither execute-command nor load-theme, calling execute-command, accepting load-theme and then solarized-dark puts that theme in force, as the scene line names it; a config command bound to SPC f f shows SPC f f as its annotation; the binding search lists SPC y y with its command and description, and accepting it runs yy-said"
      run :=
        withHost context [("10-commands.lean", commandChunk true)]
          (fun session => do
            let asked (typed : String) : IO (Array String) := do
              session.ask [.run ExecuteCommand.name]
              unless ← Event.post (.commit typed) do
                return #[]
              let asking ← session.sceneLines
              session.pressKeys cancelKeys
              return asking
            let answered (typed : String) : IO Bool := do
              unless ← Event.post (.commit typed) do
                return false
              session.pressKeys acceptKeys
              return true
            let drawnIn : IO String := do
              return ((← session.sceneLines).filter (·.startsWith "scene ")).back?.getD ""
            session.ask [.reload]
            let configs ← asked "zz-"
            let compiled ← asked "load"
            session.write "10-commands.lean" (commandChunk false)
            session.ask [.reload]
            let dropped ← asked "zz-"
            let before ← drawnIn
            session.ask [.run ExecuteCommand.name]
            unless ← answered Themes.loadName do
              return false
            unless ← answered Themes.Solarized.dark.name do
              return false
            let after ← drawnIn
            session.ask [.run BindingSearch.name]
            unless ← Event.post (.commit "SPC y") do
              return false
            let searching ← session.sceneLines
            session.pressKeys acceptKeys
            let said := (← session.scene).1
            return listsAfter configs ExecuteCommand.label ["zz-other  SPC f f", "zz-mine"] &&
                listsAfter compiled ExecuteCommand.label [Themes.loadName] &&
                listsAfter dropped ExecuteCommand.label ["zz-other  SPC f f"] &&
                before.endsWith s!", theme {Theme.defaultName.quote}" &&
                after.endsWith s!", theme {Themes.Solarized.dark.name.quote}" &&
                listsAfter searching BindingSearch.label ["SPC y y  yy-said  Say it"] &&
                said == "said".quote &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          commandCompiled }]

/-- A chunk whose `setup` registers `leader-find`, which says `leader find`
in the echo area, and `other`, which says `other`, binds `<leader> f f` to
`leader-find`, and, given `leader`, sets the leader to the key string
`leader`. -/
def leaderChunk (leader : Option String := none) : String :=
  "def setup : SetupM Unit := do
  command \"leader-find\" (message \"leader find\")
  command \"other\" (message \"other\")
  bindKey \"<leader> f f\" \"leader-find\"
" ++
    (leader.map fun keys => s!"  leaderKey {keys.quote}\n").getD ""

/-- The checks of the leader through a host of the Vim scheme that ships
(`withVimHost`), with the real elaborator and the recorder: a config's
binding written with `<leader>` is reached under the scheme's leader, `SPC`,
under the leader config sets once it is reloaded, and is kept out of
insert state, where `SPC` types a space (`Editor/Setup.lean`, the leader;
`docs/design/keymaps-and-modes.md`, "Extending from config"). How the
placeholders expand and where a binding holds is pinned by `ModelTest`'s
checks of the notation, the registry and the Vim scheme. -/
def leaderChecks (context : Context) : List Check :=
  [{  name :=
        "under the Vim scheme with no leader set by config, a config binding of <leader> f f runs its command on SPC f f in normal state"
      run :=
        withVimHost context [("10-leader.lean", leaderChunk)] fun session => do
          session.ask [.reload]
          session.typed "SPC f f"
          return (← session.echo) == "leader find".quote },
    { name :=
        "a config that sets the leader to \\ reaches its <leader> f f binding on \\ f f after a reload, and SPC f f no longer runs it"
      run :=
        withVimHost context [("10-leader.lean", leaderChunk)] fun session => do
          session.ask [.reload]
          session.write "10-leader.lean" (leaderChunk (some "\\"))
          session.ask [.reload]
          session.typed "\\ f f"
          let moved ← session.echo
          session.ask [.run "other"]
          session.typed "SPC f f"
          let spaced ← session.echo
          return moved == "leader find".quote && spaced != "leader find".quote },
    { name :=
        "SPC typed in insert state inserts a space in a config that binds keys under <leader>, and SPC f f after <Escape> still runs the binding"
      run :=
        withVimHost context [("10-leader.lean", leaderChunk)] fun session => do
          session.ask [.reload]
          session.typed "i a SPC b <Escape>"
          let line := lastViewLine (← session.sceneLines)
          let before ← session.echo
          session.typed "SPC f f"
          let after ← session.echo
          return (line.splitOn s!"{"a b".quote}, scroll").length == 2 &&
              before != "leader find".quote &&
              after == "leader find".quote }]

/-- A chunk whose `setup` registers `leader-find`, which says `leader find`
in the echo area, binds `<leader> f f` to it described as `Find file`, and,
when `named`, names the prefix `<leader> f` `file`. It sets the key hint
delay to 0, so the hints are in the scene after the prefix with no move of
the clock: what they list is checked apart from when (`keyHintChecks`). -/
def hintChunk (named : Bool) : String :=
  "def setup : SetupM Unit := do
  command \"leader-find\" (message \"leader find\")
  bindKey \"<leader> f f\" \"leader-find\" (desc := \"Find file\")
  keyHintDelay 0
" ++
    if named then "  prefixName \"<leader> f\" \"file\"\n" else ""

/-- Asks the host for the scene, and returns its key hint lines: the lines
that start with `hint `. -/
def Session.hints (session : Session) : IO (Array String) := do
  return (← session.sceneLines).filter (·.startsWith "hint ")

/-- The checks of the key hints through a host of the Vim scheme that ships
(`withVimHost`), with the real elaborator: a config's description of a
binding and its name of a prefix are in the scene's hints once it is
reloaded, and a reload that drops the name drops it from them. What the
hints list, and in which order, is pinned by `ModelTest`'s checks of the
keymap, the Vim scheme and the loop. -/
def hintChecks (context : Context) : List Check :=
  [{  name :=
        "criterion 4: after a reload, SPC lists f as the prefix config named, SPC f lists f as the binding config described, and SPC f f runs it and lists nothing"
      run :=
        withVimHost context [("10-hint.lean", hintChunk true)] fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let afterLeader ← session.hints
          session.typed "<Escape>"
          session.typed "SPC f"
          let afterPrefix ← session.hints
          session.typed "f"
          let afterBinding ← session.hints
          return afterLeader.contains "hint f: prefix \"file\" 1" &&
              afterPrefix == #["hint f: binding \"Find file\""] &&
              afterBinding.isEmpty &&
              (← session.echo) == "leader find".quote },
    { name :=
        "criterion 5: a reload that drops a config's prefix name drops it from the hints, and the prefix is listed unnamed"
      run :=
        withVimHost context [("10-hint.lean", hintChunk true)] fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let named ← session.hints
          session.typed "<Escape>"
          session.write "10-hint.lean" (hintChunk false)
          session.ask [.reload]
          session.typed "SPC"
          let unnamed ← session.hints
          return named.contains "hint f: prefix \"file\" 1" &&
              unnamed.contains "hint f: prefix - 1" &&
              !unnamed.any (·.startsWith "hint f: prefix \"file\"") }]

/-- A chunk whose `setup` registers `leader-find`, which says `leader find`
in the echo area, binds `<leader> f f` to it described as `Find file` and
`<leader> s` described as `Save`, and names the prefix `<leader> f` `file`;
with `keyHintDelay` and `delay` when one is given, and, with `display`,
defines `Display.plain "plain"` and chooses it for the category `key`. -/
def delayChunk (delay : Option String) (display : Bool := false) : String :=
  "def setup : SetupM Unit := do
  command \"leader-find\" (message \"leader find\")
  bindKey \"<leader> f f\" \"leader-find\" (desc := \"Find file\")
  bindKey \"<leader> s\" \"leader-find\" (desc := \"Save\")
  prefixName \"<leader> f\" \"file\"
" ++
    (delay.map (s!"  keyHintDelay {·}\n")).getD "" ++
    if display then
      "  defineDisplay (Completion.Display.plain \"plain\")\n  useDisplayFor \"key\" \"plain\"\n"
    else ""

/-- The hints `delayChunk` gives after `SPC`, in the scheme's order. -/
def leaderHints : Array KeyHint :=
  #[{ key := "f", leads := .prefix (some "file") 1 },
    { key := "s", leads := .binding (some "Save") }]

/-- The rows `display` draws of `hints` as the key hints' list: a listing of
their candidates (`Completion.Keys.candidates`) of the category `key`, with
nothing chosen. -/
def hintSheetRows (hints : Array KeyHint)
    (display : Completion.Display := Completion.Displays.minibuffer) : List String :=
  (display.sheet
        { listed := (Completion.Keys.candidates hints).map (Completion.Listed.of ·)
          category := some Completion.Keys.category }).rows.toList.map
    (·.text)

/-- Whether a status line of `lines` holds `text` as the first field on its
right side, in `mode-line.secondary`: the pending keys' segment. -/
def pendingDrawn (lines : Array String) (text : String) : Bool :=
  lines.any fun line =>
    line.startsWith "status " &&
      (line.splitOn s!" | {ModeLine.secondaryFace.name} {text.quote} +{ModeLine.padding}").length ==
        2

/-- Whether no status line of `lines` draws pending keys under the leader:
none holds a field in `mode-line.secondary` that starts with `SPC`. -/
def noPendingDrawn (lines : Array String) : Bool :=
  !lines.any fun line =>
      line.startsWith "status " && (line.splitOn s!"{ModeLine.secondaryFace.name} \"SPC").length > 1

/-- The checks of when and where the key hints are shown, and of the pending
keys drawn, through a host of the Vim scheme that ships (`withVimHost`),
with the real elaborator, the fake clock the host's waits are on and the
recorder: the phase's five criteria, a delay of `.never`, a reload while a
prefix is pending (the publish after an install, `Headless.Running.publish`),
and the delays a reload refuses. What the hints list is `hintChecks`'; how the delay is
armed and the list placed, `ModelTest`'s. -/
def keyHintChecks (context : Context) : List Check :=
  [{  name :=
        "AC1: after SPC in normal state and the default delay on the fake clock, the scene lists the keys that can follow SPC with their descriptions and prefix names, drawn by the minibuffer display directly above the bottom row; none before the delay has passed"
      run :=
        withVimHost context [("10-hint.lean", delayChunk none)] fun session => do
          session.host.resize 640 480
          session.ask [.reload]
          session.typed "SPC"
          let pending ← session.sceneLines
          let armed := (← session.clock.waiting) == 1
          session.clock.advance 499
          let early := (← session.host.join patience) == .settled
          let before ← session.sceneLines
          session.clock.advance 1
          let joined := (← session.host.join patience) == .settled
          let after ← session.sceneLines
          let heights := Headless.cells.heights
          let listed := hintSheetRows leaderHints
          let rect := (listViewId after).bind (printedRect after)
          return armed && early && joined && (listViewId pending).isNone &&
              !pending.any (·.startsWith "hint ") &&
              (listViewId before).isNone &&
              !before.any (·.startsWith "hint ") &&
              after.filter (·.startsWith "hint ") ==
                #["hint f: prefix \"file\" 1", "hint s: binding \"Save\""] &&
              listViewShows after listed &&
              rect.map (fun (_, y, _, height) => y + height) == some (480 - heights.message) },
    { name :=
        "AC2: completing the sequence, or resetting it with an unbound key, before the delay passes withdraws the delay and leaves no hints in the scene after it"
      run :=
        withVimHost context [("10-hint.lean", delayChunk none)] fun session => do
          session.ask [.reload]
          let withdrawnBefore := (← session.clock.withdrawn).size
          session.typed "SPC f f"
          let completed := (← session.echo) == "leader find".quote
          let afterCompleting := (← session.clock.waiting) == 0
          let withdrawnOnce := (← session.clock.withdrawn).size == withdrawnBefore + 1
          session.clock.advance 500
          let completedLines ← session.sceneLines
          session.typed "SPC z"
          let afterReset := (← session.clock.waiting) == 0
          session.clock.advance 500
          let resetLines ← session.sceneLines
          return completed && afterCompleting && withdrawnOnce && afterReset &&
              (listViewId completedLines).isNone &&
              !completedLines.any (·.startsWith "hint ") &&
              (listViewId resetLines).isNone &&
              !resetLines.any (·.startsWith "hint ") },
    { name :=
        "AC3: a config that sets the delay to 0 shows the hints in the first scene after the prefix, with no wait on the clock"
      run :=
        withVimHost context [("10-hint.lean", delayChunk (some "0"))] fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let lines ← session.sceneLines
          return (← session.clock.waiting) == 0 &&
              lines.filter (·.startsWith "hint ") ==
                #["hint f: prefix \"file\" 1", "hint s: binding \"Save\""] &&
              listViewShows lines (hintSheetRows leaderHints) },
    { name :=
        "AC4: the pending prefix is drawn in the selected window's status line while a sequence is pending, SPC then SPC f, and cleared when it completes"
      run :=
        withVimHost context [("10-hint.lean", delayChunk none)] fun session => do
          session.ask [.reload]
          let rest ← session.sceneLines
          session.typed "SPC"
          let leader ← session.sceneLines
          session.typed "f"
          let prefixed ← session.sceneLines
          session.typed "f"
          let completed ← session.sceneLines
          return noPendingDrawn rest && pendingDrawn leader "SPC" &&
              pendingDrawn prefixed "SPC f" &&
              noPendingDrawn completed &&
              (← session.echo) == "leader find".quote },
    { name :=
        "AC5: a display config sets for the key category draws the hints: the fake display's rows, not the minibuffer display's"
      run :=
        withVimHost context [("10-hint.lean", delayChunk (some "0") (display := true))]
          fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let lines ← session.sceneLines
          let plain := hintSheetRows leaderHints (Completion.Display.plain "plain")
          return plain == ["  f", "  s"] && listViewShows lines plain &&
              !listViewShows lines (hintSheetRows leaderHints) },
    { name :=
        "a config that sets the delay to .never arms no wait and shows no hints however long the prefix is pending, and the pending keys are still drawn"
      run :=
        withVimHost context [("10-hint.lean", delayChunk (some ".never"))] fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let armed ← session.clock.waiting
          session.clock.advance 10000
          let joined := (← session.host.join patience) == .settled
          let lines ← session.sceneLines
          return armed == 0 && joined && (listViewId lines).isNone &&
              !lines.any (·.startsWith "hint ") &&
              pendingDrawn lines "SPC" },
    { name :=
        "a reload that sets the delay to .never while SPC is pending with its hints shown closes them: the scene after it lists no hints and draws no list, and SPC is still drawn pending"
      run :=
        withVimHost context [("10-hint.lean", delayChunk (some "0"))] fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let shown ← session.sceneLines
          session.write "10-hint.lean" (delayChunk (some ".never"))
          session.ask [.reload]
          let lines ← session.sceneLines
          return shown.any (·.startsWith "hint ") && (listViewId shown).isSome &&
              (listViewId lines).isNone &&
              !lines.any (·.startsWith "hint ") &&
              pendingDrawn lines "SPC" },
    { name :=
        "a reload before the default delay has passed keeps its wait when the delay is still wanted, so the hints are shown 500 ms after SPC; one that sets .never withdraws the wait, and one that then sets the delay again arms a new wait of the whole delay, all with SPC still pending"
      run :=
        withVimHost context [("10-hint.lean", delayChunk none)] fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let armed := (← session.clock.waiting) == 1
          let withdrawnArmed := (← session.clock.withdrawn).size
          session.clock.advance 200
          discard <| session.host.join patience
          -- A reload that leaves the delay as it was: the wait is kept.
          session.ask [.reload]
          let kept :=
            (← session.clock.waiting) == 1 && (← session.clock.withdrawn).size == withdrawnArmed
          session.clock.advance 299
          discard <| session.host.join patience
          let early ← session.sceneLines
          session.clock.advance 1
          discard <| session.host.join patience
          let due ← session.sceneLines
          session.typed "<Escape>"
          session.typed "SPC"
          let withdrawnPending := (← session.clock.withdrawn).size
          -- A reload that sets `.never`: the wait is withdrawn.
          session.write "10-hint.lean" (delayChunk (some ".never"))
          session.ask [.reload]
          let closed :=
            (← session.clock.waiting) == 0 &&
              (← session.clock.withdrawn).size == withdrawnPending + 1
          -- A reload that sets the delay again: a new wait of the whole delay.
          session.write "10-hint.lean" (delayChunk none)
          session.ask [.reload]
          let rearmed := (← session.clock.waiting) == 1
          session.clock.advance 499
          discard <| session.host.join patience
          let rearmedEarly ← session.sceneLines
          session.clock.advance 1
          discard <| session.host.join patience
          let rearmedDue ← session.sceneLines
          return armed && kept && !early.any (·.startsWith "hint ") &&
              due.filter (·.startsWith "hint ") ==
                #["hint f: prefix \"file\" 1", "hint s: binding \"Save\""] &&
              closed &&
              rearmed &&
              !rearmedEarly.any (·.startsWith "hint ") &&
              pendingDrawn rearmedEarly "SPC" &&
              rearmedDue.filter (·.startsWith "hint ") ==
                #["hint f: prefix \"file\" 1", "hint s: binding \"Save\""] },
    { name :=
        "a reload refuses a delay over a minute, saying keyHintDelayTooLong's sentence, a delay that is not one, and a delay set twice; the previous config's bindings keep working"
      run :=
        withVimHost context [("10-hint.lean", delayChunk (some "0"))] fun session => do
          session.ask [.reload]
          -- The frame is made, so each refusal is said in its echo area.
          session.typed "<Escape>"
          let refusedWith (delay : String) : IO (Bool × String) := do
            session.write "10-hint.lean" (delayChunk (some delay))
            let before := (← session.output.get).size
            session.ask [.reload]
            let printed := (← session.output.get).extract before
            return (printed.any fun line => line.startsWith "reload " && line.endsWith ": rejected",
                ← session.echo)
          let (tooLong, tooLongEcho) ← refusedWith "60001"
          let (notADelay, _) ← refusedWith "0.5"
          let (twice, twiceEcho) ← refusedWith "0\n  keyHintDelay 250"
          session.typed "SPC f f"
          return tooLong &&
              (tooLongEcho.splitOn (Completion.Keys.keyHintDelayTooLong 60001)).length == 2 &&
              notADelay &&
              twice &&
              (twiceEcho.splitOn Config.Registrations.keyHintDelayTwice).length == 2 &&
              (← session.echo) == "leader find".quote }]

/-- The registrations of the default config (`config/default`, the
directory `context.defaultConfig` names), built as a reload builds them
(`Config.build`), under the Vim scheme that ships, with the real
elaborator. Throws with the diagnostics when the build is rejected, so a
check that fails says why. -/
def defaultBuilt (context : Context) : IO Config.Registrations := do
  let outcome ←
    Config.build Vim.Default.scheme context.elaborator
        (Config.Directory.source context.defaultConfig) (some context.base) #[]
  match outcome.built with
  | some built =>
    return built.registrations
  | none =>
    throw <|
        IO.userError
          s!"the default config was rejected: {outcome.diagnostics.toList.map (·.message)}"

/-- The registry a host of the executable starts with
(`Headless.shippedOver`), with the default config's bindings, prefix names
and leaders installed for the owner `.config`, as a reload installs them
(`Config.Reload.install`). -/
def defaultRegistry (registrations : Config.Registrations) : IO Config.Registry := do
  let completions ← Job.Completions.new
  let clock ← Job.FakeClock.new completions
  let shipped :=
    Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
      (← Snapshots.new) (← Job.HeldSnapshots.new)
  let registry :=
    ((Headless.compiled shipped).replaceBindings .config registrations.bindings).replacePrefixNames
      .config registrations.prefixNames
  return { registry with
      leader := registrations.leader, localLeader := registrations.localLeader }

/-- The checks of the default config `mise run install` ships
(`config/default`), read from the directory the fourth argument names: it
loads with no reload error and `SPC f f` opens a file, each binding names a
registered command, and each prefix it binds under the leader is named. -/
def defaultConfigChecks (context : Context) : List Check :=
  [{  name :=
        "the default config: a reload installs it with no diagnostic; SPC f f then runs open-file, which asks for a path, once that is cancelled SPC : opens the command prompt, and once that is cancelled SPC ? opens the binding search, which, once open is typed, lists SPC f f  open-file"
      run := do
        let files ← chunksOf context.defaultConfig
        withVimHost context files.toList fun session => do
            session.ask [.reload]
            let output ← session.output.get
            let installed := output.any (·.startsWith "reload 1: installed")
            let clean := !output.any (·.startsWith "diagnostic:")
            let before ← session.sceneLines
            session.typed "SPC f f"
            let joined := (← session.host.join patience) == .settled
            let after ← session.sceneLines
            session.typed "<Escape>"
            let cancelled ← session.sceneLines
            session.typed "SPC :"
            let rejoined := (← session.host.join patience) == .settled
            let commanding ← session.sceneLines
            session.typed "<Escape>"
            session.typed "SPC ?"
            let searched := (← session.host.join patience) == .settled
            let searching ← session.sceneLines
            -- The list shows only its first rows: typing `open` narrows it
            -- to the bindings that match.
            session.typed "o p e n"
            let narrowed := (← session.host.join patience) == .settled
            let opening ← session.sceneLines
            -- Each prompt opens a minibuffer view of its own, so a prompt's
            -- status line is compared from its view's id on.
            let promptOf (label : String) (lines : Array String) : Bool :=
              lines.any fun line =>
                line.startsWith "status " && afterId line == afterId (promptStatus label)
            return installed && clean && joined && rejoined && searched && narrowed &&
                !before.contains (promptStatus Files.openPrompt) &&
                after.contains (promptStatus Files.openPrompt) &&
                !cancelled.contains (promptStatus Files.openPrompt) &&
                !promptOf ExecuteCommand.label cancelled &&
                promptOf ExecuteCommand.label commanding &&
                !promptOf BindingSearch.label commanding &&
                promptOf BindingSearch.label searching &&
                opening.any fun line =>
                  line.startsWith "view " && (afterId line).contains "SPC f f  open-file" },
    { name :=
        "the default config: every binding names a command registered compiled or by the config, <leader> f f is bound to open-file, <leader> : to execute-command, described Execute command, and <leader> ? to search-bindings, described Search bindings"
      run := do
        let registrations ← defaultBuilt context
        let registry ← defaultRegistry registrations
        let unregistered :=
          registrations.bindings.filter fun binding =>
            (registry.find? binding.command).isNone &&
              !registrations.commands.any (·.name == binding.command)
        unless unregistered.isEmpty do
          throw <| IO.userError s!"unregistered commands: {unregistered.toList.map (·.command)}"
        return !registrations.bindings.isEmpty &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> f f" &&
                  binding.command == Files.openName) &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> :" &&
                  binding.command == ExecuteCommand.name &&
                  binding.desc == some "Execute command") &&
            registrations.bindings.any fun binding =>
              Key.strokeNotations binding.keys == "<leader> ?" &&
                binding.command == BindingSearch.name &&
                binding.desc == some "Search bindings" },
    { name :=
        "the default config: every prefix it binds under the leader has a prefix name, and those prefixes are SPC f, SPC b, SPC w, SPC TAB and SPC h"
      run := do
        let registrations ← defaultBuilt context
        let registry ← defaultRegistry registrations
        let leaders := registry.leaders Vim.Default.scheme
        let leader := leaders.leader.map Key.chord
        let mut prefixes : Array (List Key) := #[]
        for binding in registrations.bindings do
          let keys := (Key.expand leaders binding.keys).map Key.chord
          unless keys.take leader.length == leader do
            continue
          for n in [leader.length + 1:keys.length] do
            let begun := keys.take n
            unless prefixes.contains begun do
              prefixes := prefixes.push begun
        let unnamed :=
          prefixes.filter fun begun => (registry.prefixName? Vim.Default.scheme begun).isNone
        unless unnamed.isEmpty do
          throw <| IO.userError s!"unnamed prefixes: {unnamed.toList.map Key.notations}"
        let expected :=
          ["SPC f", "SPC b", "SPC w", "SPC TAB", "SPC h"].map fun text =>
            (keysOf text).map Key.chord
        return prefixes.size == expected.length && expected.all prefixes.contains }]

/-- Every check, in the order they run. -/
def checks (context : Context) : List Check :=
  elaboratorChecks context ++ directoryChecks () ++ hostChecks context ++ threadChecks context ++
    jobChecks context ++
    treeObjectChecks context ++
    indentChecks context ++
    watchReloadChecks context ++
    agreementChecks () ++
    shippedChecks () ++
    scriptChecks context ++
    dispatchChecks context ++
    hostLoopChecks context ++
    modeChecks context ++
    promptChecks context ++
    filePromptChecks context ++
    atPointChecks context ++
    exChecks context ++
    evilChecks context ++
    reloadEchoChecks context ++
    faceChecks context ++
    cursorResolutionChecks () ++
    themeChecks context ++
    commandPromptChecks context ++
    environmentHostChecks context ++
    fileChecks context ++
    languageChecks context ++
    reloadChecks context ++
    autoReloadChecks context ++
    gutterChecks context ++
    exScriptChecks context ++
    leaderChecks context ++
    hintChecks context ++
    keyHintChecks context ++
    defaultConfigChecks context

end ConfigTest

/-- `config-test <sysroot> <olean dir> <syntax fixtures> <default config>`
runs the checks: exits 0 when all hold, and 1 after naming the ones that do
not. The third argument is the directory of the syntax fixtures
(`tests/syntax`), which the indent checks read, and the fourth the directory
of the default config (`config/default`), which `defaultConfigChecks` read.

`bench-start`, `bench-reload` and `bench-soak` are the benchmark
(`ConfigTest.Bench`; `mise run config-bench`), which the gate never runs.
`bench-modules` lists the modules an import set reads, for
`mise run module-bench` and the gate's `bundle-test`.
`bench-jobs` is the job benchmark (`ConfigTest.Bench.jobs`;
`mise run job-bench`), which the gate never runs either, and so is
`bench-prompt`, the prompt benchmark (`ConfigTest.Bench.prompt`;
`mise run prompt-bench`).

Any other command line is reported, with the exit status 2.

It exits explicitly: a failed check may have left a task parked in the
library, and a benchmark leaves its host's loop running; returning from
`main` would wait for either for ever. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | "bench-start" :: sysroot :: oleanDir :: module :: modules =>
    IO.Process.exit (← ConfigTest.Bench.start sysroot oleanDir (module :: modules))
  | "bench-modules" :: sysroot :: oleanDir :: module :: modules =>
    IO.Process.exit (← ConfigTest.Bench.modules sysroot oleanDir (module :: modules))
  | ["bench-reload", sysroot, oleanDir] =>
    IO.Process.exit (← ConfigTest.Bench.reload sysroot oleanDir)
  | ["bench-soak", sysroot, oleanDir, count] =>
    match count.toNat? with
    | some count =>
      IO.Process.exit (← ConfigTest.Bench.soak sysroot oleanDir count)
    | none =>
      ConfigTest.usage
  | ["bench-jobs", sysroot, oleanDir, samples] =>
    match samples.toNat? with
    | some samples =>
      -- A benchmark that fails leaves tasks running, so it says why and
      -- exits here: an error that left `main` would wait for them for ever.
      let status ←
        try
          ConfigTest.Bench.jobs sysroot oleanDir samples
        catch error =>
          IO.eprintln s!"config-test: bench-jobs: {error}"
          pure 1
      IO.Process.exit status
    | none =>
      ConfigTest.usage
  | ["bench-prompt", sysroot, oleanDir, samples] =>
    match samples.toNat? with
    | some samples =>
      let status ←
        try
          ConfigTest.Bench.prompt sysroot oleanDir samples
        catch error =>
          IO.eprintln s!"config-test: bench-prompt: {error}"
          pure 1
      IO.Process.exit status
    | none =>
      ConfigTest.usage
  | [sysroot, oleanDir, syntaxFixtures, defaultConfig] =>
    IO.Process.exit
        (← ConfigTest.run ConfigTest.checks sysroot oleanDir syntaxFixtures defaultConfig)
  | _ =>
    ConfigTest.usage
