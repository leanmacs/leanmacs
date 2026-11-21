import Editor.Config.Registry
import Editor.Event
import Editor.Headless
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Key.Notation
import Editor.Role
import Editor.Test.Linked.Host

/-!
# Config tests: support: Keys

Keys typed into a session: the keys a key string names, typing and pressing them
(`Session.type`, `Session.typed`, `Session.pressKeys`), a binding of them, and
the keys of the roles `next-item`, `activate` and `quit` under the test scheme.
Shared by several test modules; it holds no checks of its own.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The keys the key string `text` names; none when it is refused. -/
def keysOf (text : String) : List Key :=
  (Key.parse text).toOption.getD []

/-- Sends a press of each key the key string `text` names, in order, as the
window would report them. -/
def _root_.Editor.Test.Linked.Session.type (session : Session) (text : String) : IO Unit := do
  for key in keysOf text do
    session.host.press key

/-- Sends a press of each key the key string `text` names, and waits until
the editor thread has handled them. Throws if that takes longer than
`patience`. -/
def _root_.Editor.Test.Linked.Session.typed (session : Session) (text : String) : IO Unit := do
  session.type text
  session.ask []

/-- Sends a press of each of `keys`, in order, and waits until the editor
thread has handled them. Throws if that takes longer than `patience`. -/
def _root_.Editor.Test.Linked.Session.pressKeys (session : Session) (keys : List Key) : IO Unit :=
  do
  for key in keys do
    session.host.press key
  session.ask []

/-- The binding of the keys the key string `text` names to the command
`command`. -/
def bound (text command : String) : Config.KeyBinding :=
  .ofKeys (keysOf text) command

/-- The keys of the role `next-item` under the test scheme. -/
def nextItemKeys : List Key :=
  (TestScheme.scheme.roleKey Role.nextItem).getD []

/-- The keys of the role `activate` under the test scheme: the minibuffer's
accept key, since its mode fills that role with the accept command. -/
def acceptKeys : List Key :=
  (TestScheme.scheme.roleKey Role.activate).getD []

/-- The keys of the role `quit` under the test scheme: the minibuffer's
cancel key. -/
def cancelKeys : List Key :=
  (TestScheme.scheme.roleKey Role.quit).getD []

end ConfigTest
