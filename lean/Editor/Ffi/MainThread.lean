/-!
# Bindings: the main thread

The bindings of `crates/editor-ffi/src/main_thread.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("The window", "An exception from the interpreter ends the process").

The two stack readouts read what the glue's entry point (`ffi/glue.c`) set.
-/

namespace Editor.Ffi

/-- Whether the calling thread is the process's main thread. Lean's `main` runs
on a thread Lean creates, so in Lean code this is `false`. -/
@[extern "editor_glue_is_main_thread"]
opaque isMainThread : IO Bool

/-- Whether work handed to the main-thread service runs on the process's main
thread. Blocks until the service has answered. `true` in an executable whose
entry point parks the main thread in the service (`editor_entry` in
`ffi/glue.c`); this is the path a window will take. -/
@[extern "editor_glue_main_thread_probe"]
opaque mainThreadProbe : IO Bool

/-- The stack size, in bytes, of the thread the entry point runs Lean's
generated `main` on, as the operating system reports it; 0 if the executable
did not start at the entry point. Module initialisers run on that thread.

This exists for `FfiTest`, which checks the entry point asked for a large
stack. The editor has no use for it. -/
@[extern "editor_glue_entry_stack_size"]
opaque entryStackSize : IO USize

/-- The stack size, in bytes, of the calling thread, as the operating system
reports it.

This exists for `FfiTest`, which checks that every thread Lean creates has the
stack the entry point sets. The editor has no use for it. -/
@[extern "editor_glue_thread_stack_size"]
opaque threadStackSize : IO USize

end Editor.Ffi
