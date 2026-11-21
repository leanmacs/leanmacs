import Editor.Ffi
import Editor.Headless.Queue

/-!
# The editor queue port, over the library

The binding of the editor queue port (`Editor/Headless/Queue.lean`) to the
library's editor queue: `Queue.library`, which posts through
`Ffi.postEvent` and is pulled by a real loop on its own thread
(`Headless.loop`), and `Posted.toFfi`, the event the library hands back for
a post, which a stepped host's memory queue holds in its place. It is the
only queue module that imports `Editor.Ffi`, as `Editor/Text/Real.lean` is
for the text port, so only an executable linked with the library reaches
it. `ContractTest.queueContractChecks` run the port's contract against it,
and `ContractTest.queueRealChecks` show that what the library hands back is
`Posted.toFfi` of the post.
-/

namespace Editor.Headless

/-- The library's editor queue as the port: a post is `Ffi.postEvent` on the
editor queue under its source, refused once the queues are quit, and a real
loop pulls it (`pulledBy := .library`). -/
def Queue.library : Queue where
  post posted :=
    (Ffi.postEvent .editor posted.source posted.code posted.text : IO Bool).catchExceptions fun _ =>
      pure false
  pulledBy := .library

/-- The event the library hands back for `posted`: from the Lean source of
its id, a message with its code and its text, no words and no stamp. -/
def Posted.toFfi (posted : Posted) : Ffi.Event :=
  { source := { kind := .lean, id := posted.source }, kind := .message, code := posted.code
    text := posted.text, stamp := 0 }

end Editor.Headless
