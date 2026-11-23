import Editor.Bound

/-!
# Bindings: the counter

The bindings of `crates/editor-ffi/src/counter.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Handles").

`add`, the plain call (`lib.rs`'s), is here beside it: the two smallest
examples of the boundary.
-/

namespace Editor.Ffi

/-- The sum of `a` and `b`, wrapping on overflow, computed by the Rust library.
The trivial function that shows a call crossing the boundary. -/
@[extern "editor_ffi_add"]
opaque add (a b : UInt32) : UInt32

/-- The type behind `Counter`. It is opaque, so the only way to get a counter
is `Counter.new`. -/
opaque CounterPointed : NonemptyType

/-- A counter held by the Rust library: the example of a handle. The value is
a Lean external object, and its finaliser, run when the last reference is
dropped, is the only thing that frees the Rust object. -/
def Counter : Type :=
  CounterPointed.type

instance : Nonempty Counter :=
  CounterPointed.property

/-- A new counter starting at `start`. -/
@[extern "editor_glue_counter_new"]
opaque Counter.new (start : UInt64) : IO Counter

/-- Adds one to the counter and returns the new value, wrapping on overflow. -/
@[extern "editor_glue_counter_increment"]
opaque Counter.increment (counter : @& Counter) : IO UInt64

/-- How many counters the Rust library holds that have not been freed.

This exists for `FfiTest`, which uses it to see a counter's finaliser run. -/
@[extern "editor_glue_counter_live"]
opaque Counter.live : IO UInt64

/-- `Counter.awaitLive` as it crosses: the kind 3 names counters. -/
@[extern "editor_glue_live_await"]
private opaque Counter.liveAwaitRaw (kind : UInt8) (target boundMs : UInt64) : IO Bool

/-- Waits until at most `target` counters the Rust library holds are not freed
(`Counter.live`), and says whether that came: false once `guard` has
run out first. A readout for tests, which use it to see a
finaliser run on another thread: it returns on the free, never by a poll of
`Counter.live`. Only a handle that is never freed
reaches the guard. -/
def Counter.awaitLive (target : UInt64) (guard : HangGuard) : IO Bool :=
  Counter.liveAwaitRaw 3 target guard.ms.toUInt64

end Editor.Ffi
