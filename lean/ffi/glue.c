// Glue between Lean's `@[extern]` calling convention and the Rust library's
// plain C ABI (`crates/editor-ffi`).
//
// Building and taking apart Lean objects is done with `lean.h`, most of which
// is `static inline`, so it has to be done in C. Each wrapper here calls one
// Rust function and builds the Lean value for its result. Calls go one way:
// nothing in this file calls Lean code.
//
// `FfiTest.lean` pins what these functions do, as Lean sees it.

#include <lean/lean.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

// The Rust library.
bool editor_ffi_is_main_thread(void);
bool editor_ffi_main_thread_probe(void);
void editor_ffi_main_thread_open(void);
_Noreturn void editor_ffi_main_thread_serve(void);

// `Editor.Ffi.isMainThread : IO Bool`
lean_obj_res editor_glue_is_main_thread(void) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_is_main_thread()));
}

// `Editor.Ffi.mainThreadProbe : IO Bool`
lean_obj_res editor_glue_main_thread_probe(void) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_main_thread_probe()));
}

// ---- The process entry point ----
//
// Lean's generated `main` runs the Lean `main` on a thread Lean creates, so
// Lean code is never on the process's main thread, and macOS only lets a
// window event loop run there. The executables are therefore linked with
// `-Wl,-e,_editor_entry` (`lakefile.lean`), which makes `editor_entry` the
// entry point instead of `main`. It keeps the real main thread for the Rust
// library and runs Lean's unmodified `main` on a second thread. It knows
// nothing about how Lean initialises itself.

// Lean's generated `main`.
int main(int argc, char **argv);

struct entry_args {
  int argc;
  char **argv;
};

// The second thread: runs Lean, and ends the process with Lean's exit status
// while the main thread is still parked.
static void *run_lean_main(void *arg) {
  struct entry_args *args = arg;
  exit(main(args->argc, args->argv));
}

int editor_entry(int argc, char **argv) {
  static struct entry_args args;
  args.argc = argc;
  args.argv = argv;

  // Open the service before Lean can ask it for anything.
  editor_ffi_main_thread_open();

  pthread_t thread;
  if (pthread_create(&thread, NULL, run_lean_main, &args) != 0) {
    fputs("editor: cannot start the thread that runs Lean\n", stderr);
    return 70;
  }
  editor_ffi_main_thread_serve();
}
