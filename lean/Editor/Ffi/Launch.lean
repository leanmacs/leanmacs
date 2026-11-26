import Editor.Ffi.Processes

/-!
# Bindings: the exec and the main bundle

The bindings of `crates/editor-ffi/src/launch.rs`, which forwards to the
launcher's own adapters (`crates/editor-launch-std`), so the editor and the
launcher exec, and read CoreFoundation's main bundle, the same way. The
conventions they follow are in the module docs of `Editor/Ffi.lean`.

- `exec` replaces this process with another program, keeping its id and its
  standard streams: a restart's last step (`Editor/Restart/Real.lean`). It
  answers only when the exec failed, with the reason, which names the
  program; the process then carries on.
- `mainBundle` is CoreFoundation's main bundle as this process sees it: its
  path and its identifier, `none` where there is no CoreFoundation. The
  executable's `--probe` prints it (`Editor/Main.lean`), so a check sees
  the app's identity from an editor outside the bundle.

Pinned by `FfiTest.ffiLaunchChecks`: a successful exec cannot run inside
`ffi-test`, which it would replace, so the Rust contract
(`crates/editor-launch-std/tests/contract.rs`) pins it, and the restart's
hand-over and exec arguments are model-tested
(`ModelTest/Editor/Restart/Handover.lean`).
-/

namespace Editor.Ffi

/-- `exec` as it crosses: the command laid out as a run's (`runLayout`). -/
@[extern "editor_glue_exec"]
private opaque execRaw (words : @& ByteArray) (strings : @& String) : IO String

/-- Execs `program` with `arguments`, with `unset` removed from this
process's environment and `set` applied: it answers only when the exec
failed, with the reason, and this process then carries on. -/
def exec (program : String) (arguments : Array String) (set : Array (String × String) := #[])
    (unset : Array String := #[]) : IO String :=
  let (words, strings) := runLayout program arguments false set unset "/" 0
  execRaw words strings

/-- CoreFoundation's main bundle as this process sees it: its path and its
`CFBundleIdentifier`, if it has one; `none` where there is no
CoreFoundation, on any system but macOS. -/
@[extern "editor_glue_main_bundle"]
opaque mainBundle : IO (Option (String × Option String))

end Editor.Ffi
