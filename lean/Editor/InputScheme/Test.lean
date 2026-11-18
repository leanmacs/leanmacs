import Editor.InputScheme
import Editor.Key.Notation

/-!
# The test scheme

The simplest input scheme there is, published for other modules' tests: it
is the fake scheme that code above the scheme interface is tested on, so
that such a test names no shipped scheme's keys
(`docs/design/keymaps-and-modes.md`, "Who tests what"). It is the second
scheme that keeps `InputScheme` honest, and it is not shipped: the root
module `Editor` does not import it.

Its rules:

- **A binding is an invocation** (`Binding`): a key sequence is bound to a
  command's name and arguments, and completing the sequence yields exactly
  that.
- **Its state is the pending keys** (`State`) and nothing else, so after a
  reset its state is its initial state.
- **Keys are walked through the view's keymaps** with `Keymap.walk`: a
  prefix is pending and yields nothing, and an unbound key drops the prefix
  and yields nothing.
- **What can follow is listed from the same keymaps** (`continuations`):
  its state is its keymap prefix, so while keys are pending it lists
  `Keymap.continuations` of the view's keymaps after them, and nothing at
  rest.
- **Its key bindings are every sequence the walk completes from rest**
  (`keyBindings`, `Keymap.reachableOver` of the view's keymaps), each with
  its invocation's command name, whatever the state.
- **An unbound printable key with nothing pending yields a self-insert**
  (`selfInsert`), an invocation whose argument is the key's character.
  Which keys are printable is the scheme interface's (`Key.printed?`): the
  logical key is a character and none of control, alt and super is held.
- **A key bound to a command name is bound to its invocation with no
  arguments** (`scheme.command`).
- **Its role table, leader and localleader** (`roles`, `leader`,
  `localLeader`) put every registered role on a key that prints nothing, so
  none is ever a self-insert, the leader on `C-c`, Emacs's prefix for a
  mode's keys, and the localleader on the leader itself (`<leader>`), so a
  mode's suffixes are under `C-c`. A mode's tests read them through the
  scheme (`InputScheme.roleKey`, `InputScheme.leaders`) and name none of
  these keys.
- **A key bound for some states is bound as one to the command name**
  (`stateCommand`, the default): the scheme has no states of its own.

## Where an addition goes

A test that needs a scheme to do more than this wants the scheme it is
about, not a larger fake: add nothing here that a test of the scheme
interface does not need. What the test scheme must do as a scheme is the
contract check's (`Editor/InputScheme/Contract.lean`); what it does of its
own, the rules above, is pinned by `ModelTest.schemeChecks`.
-/

namespace Editor.TestScheme

/-- The test scheme's state: the keys pending and nothing else. -/
structure State where
  /-- The keys of the sequence begun and not yet completed. -/
  pending : List Key := []
  deriving DecidableEq, Repr

/-- What the test scheme's keymaps bind a key sequence to: the invocation
the sequence yields. -/
abbrev Binding :=
  Invocation

/-- The invocation an unbound printable key yields: the test scheme's
command `self-insert`, with the key's character `text` as its argument. The
name is this scheme's own. -/
def selfInsert (text : String) : Invocation :=
  { command := "self-insert", arguments := [.str text] }

/-- One key of the test scheme: the walk through the keymaps of `view`. A
key that completes a bound sequence yields its invocation; one that
continues a prefix is pending; an unbound key drops what was pending and
yields nothing, unless nothing was pending and it is printable, when it
yields `selfInsert` of its character. -/
def step (maps : ViewId → List (Keymap Binding)) (view : ViewId) (state : State) (key : Key) :
    State × Option Invocation :=
  match Keymap.walk (maps view) state.pending key with
  | (pending, some invocation) => ({ pending }, some invocation)
  | (pending, none) =>
    if state.pending.isEmpty && pending.isEmpty then ({}, key.printed?.map selfInsert)
    else ({ pending }, none)

/-- The keys a key string names, as chords; none for one `Key.parse`
refuses. -/
private def parsed (text : String) : List Key :=
  (Key.parse text).toOption.getD []

/-- The test scheme's role table, each role on keys that print nothing, so
that none is ever a self-insert. -/
def roles : List (Role × List Key) :=
  [(Role.nextItem, "C-n"), (Role.previousItem, "C-p"), (Role.activate, "RET"), (Role.quit, "C-q"),
        (Role.refresh, "<F5>"), (Role.toggle, "TAB"), (Role.mark, "C-SPC")].map
    fun (role, text) => (role, parsed text)

/-- The test scheme's leader: `C-c`, Emacs's prefix for a mode's keys. -/
def leader : List Key :=
  parsed "C-c"

/-- The test scheme's localleader: the leader itself, so a mode's suffixes
are under `C-c`. -/
def localLeader : List Key.Stroke :=
  [.leader]

/-- The keys that can follow the test scheme's pending keys in the view's
keymaps, and what the walk makes of each; none when nothing is pending. -/
def continuations (maps : ViewId → List (Keymap Binding)) (names : List Key → Option String)
    (view : ViewId) (state : State) : List (Keymap.Continuation Binding) :=
  if state.pending.isEmpty then [] else Keymap.continuations (maps view) state.pending names

/-- The key sequences the walk through the view's keymaps completes from
rest, each with its invocation's command name and its description. -/
def keyBindings (maps : ViewId → List (Keymap Binding)) (view : ViewId) (_ : State) :
    List KeyBinding :=
  (Keymap.reachableOver (maps view) []).map fun r =>
    { keys := r.keys, command := r.binding.command, desc := r.desc }

/-- The test scheme. -/
def scheme : InputScheme :=
  { State, Binding, init := {}, step, pending := (·.pending)
    command := fun name => { command := name }
    roles
    leader
    localLeader
    continuations
    keyBindings }

end Editor.TestScheme
