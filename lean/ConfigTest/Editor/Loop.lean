import ConfigTest.Check
import ConfigTest.Support.Configs
import Editor.Command
import Editor.Completion
import Editor.Config.Elaborate
import Editor.Config.Registry
import Editor.Event
import Editor.Event.Queue
import Editor.Ex.Line
import Editor.Face
import Editor.Ffi.Events
import Editor.Ffi.Interrupt
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.InputScheme.Test
import Editor.Job.Fake
import Editor.Language
import Editor.Loop
import Editor.Mode
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Text
import Editor.Watch

/-!
# Config tests: `Editor/Loop.lean`

The tests of `Editor/Loop.lean`: `dispatchChecks`, `modeChecks` and
`autoReloadChecks`, through the headless host. The root module `ConfigTest` runs
them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- A compiled command called `name` that makes a text holding `text`. -/
def making (name text : String) : Config.Registration :=
  { name, action := .plain (discard <| createText text) }

/-- What compiled code hands a host whose compiled `stamp` makes a text
holding `compiled`, on `C-c s`. -/
def stampCompiled : Compiled :=
  { commands := #[making "stamp" "compiled"], bindings := #[bound "C-c s" "stamp"] }

/-- A config whose `setup` registers a command `stamp` that makes a text
holding `config`. -/
def stampText : String :=
  "def setup : SetupM Unit := do\n  command \"stamp\" (discard <| createText \"config\")\n"

/-- A config with two commands, `one` and `two`, each of which makes a text
holding its name, and a `setup` that binds `C-c t` to `command`. -/
def bindingText (command : String) : String :=
  "def setup : SetupM Unit := do
  command \"one\" (discard <| createText \"one\")
  command \"two\" (discard <| createText \"two\")
  bindKey \"C-c t\" \"" ++
    command ++
    "\"
"

/-- A config with a store of one number, a command `bump` over it that adds
one, and a `setup` that binds `C-c u` to it. -/
def boundCounterText : String :=
  "def counter : Store Nat :=
  { name := \"counter\", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

def setup : SetupM Unit := do
  counter.declare
  counter.command \"bump\" fun n => pure (n + 1)
  bindKey \"C-c u\" \"bump\"
"

/-- A press of the interrupt key as the library hands it to a host: posted as
the window would report it, which raises the flag when the library has been
told the key, and pulled back off the editor queue, marked. What an earlier
host left on the queue is pulled past: the press is behind it, so no pull
waits. `none` when the press was not queued, or the queues were quit. -/
def interruptPulled : IO (Option Ffi.Event) := do
  unless ← Event.post (.key Watch.interruptKey true "") do
    return none
  repeat
    let event ← Ffi.nextEvent .editor
    if event.kind == .quit then
      return none
    if event.source.kind == .window && event.kind == .key then
      return some event
  return none

/-- The checks of key dispatch through the headless host, on the real queue,
the real text binding, the library's interrupt flag and the real elaborator,
with the test scheme and compiled commands and bindings written here. -/
def dispatchChecks (context : Context) : List Check :=
  [{  name :=
        "a key a compiled binding binds runs its compiled command for the focused window, and the scene shows its effect"
      run :=
        withHost context []
          (fun session => do
            session.typed "C-c s"
            return (← session.scene) == ("".quote, #[viewLine "!" 1]))
          dispatchCompiled },
    { name :=
        "a command that fails after editing: the scene's echo is its error, the view's text and its selection are those before the command, and the next key runs its command"
      run :=
        withHost context []
          (fun session => do
            unless ← Event.post (.commit "abcd") do
              return false
            let before ← session.scene
            session.typed "C-c b"
            let failed ← session.scene
            session.typed "C-c s"
            let after ← session.scene
            return before == ("".quote, #[viewLine "abcd" 4]) &&
                failed == ("boom: refused: bad range".quote, #[viewLine "abcd" 4]) &&
                after == ("".quote, #[viewLine "abcd!" 5]))
          dispatchCompiled },
    { name :=
        "the interrupt key arrives while a command loops over requests: the command stops, the scene's echo says so, the view's text is that before the command, and the next key runs its command"
      run :=
        withHost context []
          (fun session => do
            session.type "C-c l"
            -- The loop has taken the key that runs the command: it is in the
            -- command, or about to be.
            unless ← eventually (return (← session.output.get).contains "key arrived: l - -") do
              return false
            session.host.press Watch.interruptKey
            unless ← session.host.settle patience do
              return false
            let interrupted ← session.scene
            let lowered ← Ffi.interruptRaised
            session.typed "C-c s"
            let after ← session.scene
            return interrupted == ("spin: interrupted".quote, #[viewLine "" 0]) && !lowered &&
                after == ("".quote, #[viewLine "!" 1]))
          dispatchCompiled },
    { name :=
        "the interrupt key arrives while no command is running: the flag is down once the loop has taken it, and the next key's command runs to its end"
      run :=
        withHost context []
          (fun session => do
            session.host.press Watch.interruptKey
            session.ask []
            let lowered ← Ffi.interruptRaised
            session.typed "C-c s"
            return !lowered && (← session.scene) == ("".quote, #[viewLine "!" 1]))
          dispatchCompiled },
    { name :=
        "config registers a command under a compiled command's name: the key bound to the name runs config's command, and after a reload without the registration it runs the compiled one"
      run :=
        withHost context [("init.lean", stampText)]
          (fun session => do
            session.ask [.reload]
            session.typed "C-c s"
            let overridden ← session.shown
            session.write "init.lean" emptyText
            session.ask [.reload]
            session.typed "C-c s"
            let dropped ← session.shown
            return overridden == #["commands: stamp", "text 0: \"\"", "text 1: \"config\""] &&
                dropped ==
                  #["commands: stamp", "text 0: \"\"", "text 1: \"config\"",
                    "text 2: \"compiled\""] &&
                ((← session.lines).filter (·.startsWith "reload ")) ==
                  #["reload 1: installed, 1 files, 1 commands",
                    "reload 2: installed, 1 files, 0 commands"])
          stampCompiled },
    { name :=
        "a reload binds a key to a different command: the key then runs the new command, and the old one does not run again"
      run :=
        withHost context [("init.lean", bindingText "one")] fun session => do
          session.ask [.reload]
          session.typed "C-c t"
          session.write "init.lean" (bindingText "two")
          session.ask [.reload]
          session.typed "C-c t"
          return (← session.shown) ==
              #["commands: one two", "text 0: \"\"", "text 1: \"one\"", "text 2: \"two\""] },
    { name :=
        "config fails to load: the reload is rejected, and the key a compiled binding binds still runs its compiled command; and it runs it with no reload asked at all"
      run := do
        let rejected ←
          withHost context [("init.lean", "def setup : SetupM Unit := \"not a setup\"\n")]
              (fun session => do
                session.ask [.reload]
                session.typed "C-c s"
                let shown ← session.shown
                return ((← session.lines).filter (!·.startsWith "key arrived")).extract 0 2 ==
                      #["reload 1: rejected", "diagnostic: init.lean: error"] &&
                    shown == #["commands: stamp", "text 0: \"\"", "text 1: \"compiled\""])
              stampCompiled
        let unasked ←
          withHost context []
              (fun session => do
                session.typed "C-c s"
                return (← session.shown) ==
                    #["commands: stamp", "text 0: \"\"", "text 1: \"compiled\""])
              stampCompiled
        return rejected && unasked },
    { name :=
        "a key bound from config to a command over a store runs it, and what it wrote is written back: two presses leave the store at 2"
      run :=
        withHost context [("init.lean", boundCounterText)] fun session => do
          session.ask [.reload]
          session.typed "C-c u C-c u"
          return (← session.shown).contains "store counter v1: 2" },
    { name :=
        "a command that takes longer than the threshold on the fake clock produces one log entry with its name and how long it took, on the log and not on the output; a press with the clock not moved adds none"
      run :=
        withHost context []
          (fun session => do
            -- The prefix is typed first: the host reads the clock at its
            -- step, and to arm the key hint delay after it. Then the host
            -- reads the clock once at the command's step, for the time the
            -- publish records what was viewed by (`Loop.Keys.now`), and the
            -- loop reads it just before the command and just after it. Each
            -- of those readings is held, so the clock is moved between the
            -- last two and at no other time.
            session.typed "C-c"
            let step ← session.clock.holdReads
            session.type "s"
            unless ← eventually (return (← session.clock.held) == 1) do
              return false
            let first ← session.clock.holdReads
            step.resolve ()
            unless ← eventually (return (← session.clock.held) == 2) do
              return false
            let second ← session.clock.holdReads
            first.resolve ()
            unless ← eventually (return (← session.clock.held) == 3) do
              return false
            session.clock.advance 60
            second.resolve ()
            session.ask []
            let once ← session.log.get
            session.typed "C-c s"
            return once == #["slow command: stamp took 60 ms"] && (← session.log.get) == once &&
                !(← session.output.get).any (·.startsWith "slow command"))
          { dispatchCompiled with slowAfter := 50 } },
    { name :=
        "the driver's run of a compiled command that is given its call makes the frame before the first window event and runs it for the focused window, as it does once a window event has arrived"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "stamp", .run "missing"]
            unless ← Event.post (.commit "a") do
              return false
            session.ask [.run "stamp"]
            return (← session.output.get) ==
                  #["run stamp: ok", "run missing: no such command", "run stamp: ok"] &&
                (← session.scene) == ("".quote, #[viewLine "!a!" 3]))
          dispatchCompiled },
    { name :=
        "a window key the library marked as the interrupt key that cannot be read is dropped, and the flag is lowered for it, since it has been taken off the queue"
      run :=
        withRunning context id fun collaborators running stage => do
          let some pulled ← interruptPulled | return false
          let raised ← Ffi.interruptRaised
          -- A word past the key's: the mark is still on it, and it no longer
          -- reads as a key.
          let unreadable := { pulled with words := pulled.words.push 0 }
          let running ← running.handle collaborators unreadable
          return raised && (Event.ofFfi unreadable).toOption.isNone && running.frame.isNone &&
              (← stage.output.get).isEmpty &&
              !(← Ffi.interruptRaised) },
    { name :=
        "a key the library marked as the interrupt key that arrives when the host cannot make its frame is dropped, the refusal is printed, and the flag is lowered for it, since it has been taken off the queue"
      run :=
        withRunning context (fun collaborators => { collaborators with start := throw .noSuchText })
          fun collaborators running stage => do
          let some pulled ← interruptPulled | return false
          let raised ← Ffi.interruptRaised
          let running ← running.handle collaborators pulled
          return raised && running.frame.isNone &&
              (← stage.output.get).back? == some "loop: refused: no such text" &&
              !(← Ffi.interruptRaised) }]

/-- A config with a store of one number and a command `bump` over it that
adds one, and a `setup` that declares both and, when `withMode`, defines the
mode `listing`, which fills the role `next-item` with `bump`. -/
def listingText (withMode : Bool) : String :=
  "def counter : Store Nat :=
  { name := \"counter\", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

def setup : SetupM Unit := do
  counter.declare
  counter.command \"bump\" fun n => pure (n + 1)
" ++
    if withMode then "  defineMode { name := \"listing\", roles := [(Role.nextItem, \"bump\")] }\n"
    else ""

/-- What compiled code hands the host of the mode checks: `global`, which
makes a text holding `compiled`, bound to the keys of `next-item`, and the
scratch buffer in the major mode `listing`, which only config defines. -/
def listingCompiled : Compiled :=
  { commands := #[making "global" "compiled"]
    bindings := #[.ofKeys nextItemKeys "global"]
    major := some "listing" }

/-- What compiled code hands the host of the compiled mode's check: `global`
as in `listingCompiled`, the mode `compiled-listing`, which fills the role
`next-item` with `mode-next`, a command that makes a text holding `mode`,
and the scratch buffer in that mode. -/
def compiledListing : Compiled :=
  { listingCompiled with
    commands := listingCompiled.commands.push (making "mode-next" "mode")
    modes := #[{ name := "compiled-listing", roles := [(Role.nextItem, "mode-next")] }]
    major := some "compiled-listing" }

/-- The checks of modes through the headless host, with the test scheme and
the real elaborator: a mode config defines holds while config defines it.
The key a check presses is the test scheme's for a role, so no check names
a scheme's key. -/
def modeChecks (context : Context) : List Check :=
  [{  name :=
        "a role's key runs the command of the mode config defines in a view of a buffer that has the mode, a store command among them; once a reload drops the mode it runs the global binding, and the store is as it was"
      run :=
        withHost context [("init.lean", listingText true)]
          (fun session => do
            session.ask [.reload]
            session.pressKeys nextItemKeys
            let first ← session.shown
            session.write "init.lean" (listingText false)
            session.ask [.reload]
            session.pressKeys nextItemKeys
            let second ← session.shown
            return nextItemKeys.length > 0 && first.contains "store counter v1: 1" &&
                !first.any (·.endsWith "\"compiled\"") &&
                second.contains "store counter v1: 1" &&
                second.any (·.endsWith "\"compiled\""))
          listingCompiled },
    { name :=
        "a role's key runs the command of a mode compiled code hands the host in a view of a buffer that has the mode, before any reload and after a reload of a config that defines no mode"
      run :=
        withHost context [("init.lean", listingText false)]
          (fun session => do
            session.pressKeys nextItemKeys
            let first ← session.shown
            session.ask [.reload]
            session.pressKeys nextItemKeys
            let second ← session.shown
            let made (shown : Array String) (text : String) :=
              (shown.filter (·.endsWith text.quote)).size
            return nextItemKeys.length > 0 && made first "mode" == 1 &&
                made first "compiled" == 0 &&
                second.contains "store counter v1: 0" &&
                made second "mode" == 2 &&
                made second "compiled" == 0)
          compiledListing }]

end ConfigTest
