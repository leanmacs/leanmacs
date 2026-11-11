// Glue between Lean's `@[extern]` calling convention and the Rust library's
// plain C ABI (`crates/editor-ffi`).
//
// Building and taking apart Lean objects is done with `lean.h`, most of which
// is `static inline`, so it has to be done in C. A wrapper here calls one Rust
// function and builds the Lean value for its result. Calls go one way: the
// wrappers never call Lean code. The entry point at the bottom of the file
// starts Lean, once, by calling the `main` Lean generates.
//
// `FfiTest.lean` pins what this file does, as Lean sees it.

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

// The stack of the thread that runs Lean's `main`. Lean runs the module
// initialisers on it. Left alone it would get the default for a second
// thread, 512 KiB, in place of the main thread's 8 MiB.
#define ENTRY_STACK_SIZE ((size_t)64 << 20)

// The stack size of the thread `run_lean_main` runs on, as the operating
// system reports it. Read back by `FfiTest`, and by nothing else.
static size_t entry_stack_size;

// `Editor.Ffi.entryStackSize : IO USize`
lean_obj_res editor_glue_entry_stack_size(void) {
  return lean_io_result_mk_ok(lean_box_usize(entry_stack_size));
}

// The second thread: runs Lean, and ends the process with Lean's exit status
// while the main thread is still parked.
static void *run_lean_main(void *arg) {
  struct entry_args *args = arg;
  entry_stack_size = pthread_get_stacksize_np(pthread_self());
  exit(main(args->argc, args->argv));
}

int editor_entry(int argc, char **argv) {
  static struct entry_args args;
  args.argc = argc;
  args.argv = argv;

  // Open the service before Lean can ask it for anything.
  editor_ffi_main_thread_open();

  pthread_attr_t attr;
  pthread_t thread;
  if (pthread_attr_init(&attr) != 0 ||
      pthread_attr_setstacksize(&attr, ENTRY_STACK_SIZE) != 0 ||
      pthread_create(&thread, &attr, run_lean_main, &args) != 0) {
    fputs("editor: cannot start the thread that runs Lean\n", stderr);
    return 70;
  }
  editor_ffi_main_thread_serve();
}
