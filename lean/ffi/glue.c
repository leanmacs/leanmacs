// Glue between Lean's `@[extern]` calling convention and the Rust library's
// plain C ABI (`crates/editor-ffi`).
//
// Building and taking apart Lean objects is done with `lean.h`, most of which
// is `static inline`, so it has to be done in C. A wrapper here calls one Rust
// function and builds the Lean value for its result. Calls go one way: the
// wrappers never call Lean code. The entry point at the bottom of the file
// starts Lean, once, by calling the `main` Lean generates.
//
// This file stays C, and it installs no terminate or signal handler. A C++
// exception from Lean's interpreter is not caught anywhere: it ends the
// process, on purpose (`Editor/Ffi.lean`, "An exception from the interpreter
// ends the process"). `mise run ffi-overflow` shows it, on demand; it is not
// part of the gate.
//
// The conventions the wrappers follow are in the module docs of
// `Editor/Ffi.lean`. `FfiTest.lean` pins what this file does, as Lean sees
// it.

#include <lean/lean.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
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

// ---- Handles ----
//
// A Rust object crosses to Lean as an external object: a Lean object that
// carries the Rust pointer and belongs to a class whose finaliser Lean runs
// when the last reference is dropped. The finaliser is the only caller of the
// Rust `free` function. There is one class per Rust type, registered on first
// use.

// The Rust library's counter.
typedef struct editor_ffi_counter editor_ffi_counter;
editor_ffi_counter *editor_ffi_counter_new(uint64_t start);
uint64_t editor_ffi_counter_increment(const editor_ffi_counter *counter);
void editor_ffi_counter_free(editor_ffi_counter *counter);
uint64_t editor_ffi_counter_live(void);

static lean_external_class *counter_class;
static pthread_once_t counter_class_once = PTHREAD_ONCE_INIT;

// Runs when Lean drops the last reference to a counter, on whichever thread
// dropped it.
static void counter_finalize(void *counter) {
  editor_ffi_counter_free(counter);
}

// A counter holds no Lean objects, so there is nothing to visit.
static void counter_foreach(void *counter, b_lean_obj_arg visitor) {
  (void)counter;
  (void)visitor;
}

static void counter_class_register(void) {
  counter_class =
      lean_register_external_class(counter_finalize, counter_foreach);
}

// `Editor.Ffi.Counter.new : UInt64 → IO Counter`
lean_obj_res editor_glue_counter_new(uint64_t start) {
  pthread_once(&counter_class_once, counter_class_register);
  return lean_io_result_mk_ok(
      lean_alloc_external(counter_class, editor_ffi_counter_new(start)));
}

// `Editor.Ffi.Counter.increment : @& Counter → IO UInt64`
lean_obj_res editor_glue_counter_increment(b_lean_obj_arg counter) {
  return lean_io_result_mk_ok(lean_box_uint64(
      editor_ffi_counter_increment(lean_get_external_data(counter))));
}

// `Editor.Ffi.Counter.live : IO UInt64`
lean_obj_res editor_glue_counter_live(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_counter_live()));
}

// ---- Plain data ----
//
// A string goes to Rust as a pointer and a byte length, borrowed for the
// call. A structure comes back as one C record filled through an out-pointer
// in a single call, and the Lean structure is built from it here. Text in a
// record is a buffer the library owns: it is copied into a Lean string and
// handed straight back with `editor_ffi_text_free`.
//
// A Lean structure built here declares its object fields first and `UInt64`
// fields after them and nothing else, so the order of its declaration is its
// layout: object field `i` is `lean_ctor_set(o, i, …)`, and `UInt64` field
// `j` is at byte `objects * sizeof(void *) + 8 * j`.

// The byte offset of the `index`th `UInt64` field of a constructor with
// `objects` object fields.
static unsigned uint64_field(unsigned objects, unsigned index) {
  return objects * sizeof(void *) + index * sizeof(uint64_t);
}

// The bytes of a Lean string, without the terminating NUL `lean.h` counts.
static const uint8_t *string_bytes(b_lean_obj_arg string) {
  return (const uint8_t *)lean_string_cstr(string);
}
static size_t string_len(b_lean_obj_arg string) {
  return lean_string_size(string) - 1;
}

void editor_ffi_text_free(uint8_t *text, size_t len);

// The library's `ByteRange`.
typedef struct {
  uint64_t start;
  uint64_t end;
} editor_ffi_byte_range;
bool editor_ffi_text_find(const uint8_t *haystack, size_t haystack_len,
                          const uint8_t *needle, size_t needle_len,
                          bool has_start, size_t start,
                          editor_ffi_byte_range *out);

// `Editor.Ffi.findRaw : @& String → @& String → Bool → USize → Option
// ByteRange`. Pure, so the result is the value itself, not an `IO` result.
lean_obj_res editor_glue_text_find(b_lean_obj_arg haystack,
                                   b_lean_obj_arg needle, uint8_t has_start,
                                   size_t start) {
  editor_ffi_byte_range found;
  if (!editor_ffi_text_find(string_bytes(haystack), string_len(haystack),
                            string_bytes(needle), string_len(needle), has_start,
                            start, &found)) {
    return lean_box(0); // `none`
  }
  // `ByteRange`: no object fields, then `start` and `stop`.
  lean_object *range = lean_alloc_ctor(0, 0, 2 * sizeof(uint64_t));
  lean_ctor_set_uint64(range, uint64_field(0, 0), found.start);
  lean_ctor_set_uint64(range, uint64_field(0, 1), found.end);
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, range);
  return some;
}

// ---- The document ----
//
// A second handle, whose functions take a string and hand one back. It is
// the placeholder text the editor's text port is bound to
// (`Editor/Text/Real.lean`).

// The Rust library's document.
typedef struct editor_ffi_document editor_ffi_document;
// The library's `RawText`.
typedef struct {
  uint8_t *text;
  size_t text_len;
} editor_ffi_raw_text;
editor_ffi_document *editor_ffi_document_new(const uint8_t *text, size_t len);
bool editor_ffi_document_replace(const editor_ffi_document *document,
                                 size_t start, size_t end, const uint8_t *text,
                                 size_t len);
void editor_ffi_document_read(const editor_ffi_document *document,
                              editor_ffi_raw_text *out);
void editor_ffi_document_free(editor_ffi_document *document);
uint64_t editor_ffi_document_live(void);

static lean_external_class *document_class;
static pthread_once_t document_class_once = PTHREAD_ONCE_INIT;

// Runs when Lean drops the last reference to a document, on whichever thread
// dropped it. The only caller of the library's `free`.
static void document_finalize(void *document) {
  editor_ffi_document_free(document);
}

// A document holds no Lean objects, so there is nothing to visit.
static void document_foreach(void *document, b_lean_obj_arg visitor) {
  (void)document;
  (void)visitor;
}

static void document_class_register(void) {
  document_class =
      lean_register_external_class(document_finalize, document_foreach);
}

// `Editor.Ffi.Document.new : @& String → IO Document`
lean_obj_res editor_glue_document_new(b_lean_obj_arg text) {
  pthread_once(&document_class_once, document_class_register);
  return lean_io_result_mk_ok(lean_alloc_external(
      document_class,
      editor_ffi_document_new(string_bytes(text), string_len(text))));
}

// `Editor.Ffi.Document.replace : @& Document → USize → USize → @& String →
// IO Bool`
lean_obj_res editor_glue_document_replace(b_lean_obj_arg document, size_t start,
                                          size_t stop, b_lean_obj_arg text) {
  return lean_io_result_mk_ok(lean_box(
      editor_ffi_document_replace(lean_get_external_data(document), start, stop,
                                  string_bytes(text), string_len(text))));
}

// `Editor.Ffi.Document.read : @& Document → IO String`
lean_obj_res editor_glue_document_read(b_lean_obj_arg document) {
  editor_ffi_raw_text raw;
  editor_ffi_document_read(lean_get_external_data(document), &raw);
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  editor_ffi_text_free(raw.text, raw.text_len);
  return lean_io_result_mk_ok(text);
}

// `Editor.Ffi.Document.live : IO UInt64`
lean_obj_res editor_glue_document_live(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_document_live()));
}

// ---- The event queues ----
//
// Rust threads push events and Lean pulls them: nothing here calls Lean. A
// queue is named by the tag of Lean's `Editor.Ffi.Queue`, which the library
// checks.

// The library's `RawEvent`.
typedef struct {
  uint64_t source_kind;
  uint64_t source_id;
  uint64_t kind;
  uint64_t code;
  uint8_t *text;
  size_t text_len;
} editor_ffi_raw_event;
bool editor_ffi_events_post(uint8_t queue, uint64_t source_id, uint64_t code,
                            const uint8_t *text, size_t text_len);
bool editor_ffi_events_next(uint8_t queue, editor_ffi_raw_event *out);
void editor_ffi_events_quit(void);
uint64_t editor_ffi_events_waiting(uint8_t queue);
bool editor_ffi_events_script_feed(uint8_t queue, uint64_t source_id,
                                   uint64_t count);

// `Editor.Ffi.postEvent : Queue → UInt64 → UInt64 → @& String → IO Bool`
lean_obj_res editor_glue_events_post(uint8_t queue, uint64_t source_id,
                                     uint64_t code, b_lean_obj_arg text) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_events_post(
      queue, source_id, code, string_bytes(text), string_len(text))));
}

// `Editor.Ffi.nextRaw : Queue → IO RawEvent`. Blocks in Rust until the queue
// has an event.
lean_obj_res editor_glue_events_next(uint8_t queue) {
  editor_ffi_raw_event raw;
  if (!editor_ffi_events_next(queue, &raw)) {
    return lean_io_result_mk_error(lean_mk_io_user_error(
        lean_mk_string("the Rust library knows no such event queue")));
  }
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  editor_ffi_text_free(raw.text, raw.text_len);
  // `RawEvent`: `text`, then `sourceKind`, `sourceId`, `kind` and `code`.
  lean_object *event = lean_alloc_ctor(0, 1, 4 * sizeof(uint64_t));
  lean_ctor_set(event, 0, text);
  lean_ctor_set_uint64(event, uint64_field(1, 0), raw.source_kind);
  lean_ctor_set_uint64(event, uint64_field(1, 1), raw.source_id);
  lean_ctor_set_uint64(event, uint64_field(1, 2), raw.kind);
  lean_ctor_set_uint64(event, uint64_field(1, 3), raw.code);
  return lean_io_result_mk_ok(event);
}

// `Editor.Ffi.quit : IO Unit`
lean_obj_res editor_glue_events_quit(void) {
  editor_ffi_events_quit();
  return lean_io_result_mk_ok(lean_box(0));
}

// `Editor.Ffi.waiting : Queue → IO UInt64`
lean_obj_res editor_glue_events_waiting(uint8_t queue) {
  return lean_io_result_mk_ok(
      lean_box_uint64(editor_ffi_events_waiting(queue)));
}

// `Editor.Ffi.feedScript : Queue → UInt64 → UInt64 → IO Bool`
lean_obj_res editor_glue_events_script_feed(uint8_t queue, uint64_t source_id,
                                            uint64_t count) {
  return lean_io_result_mk_ok(
      lean_box(editor_ffi_events_script_feed(queue, source_id, count)));
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

// Lean's runtime: sets the stack size of every thread Lean creates from now
// on (Lean's own main thread, dedicated tasks, the pool), to which the
// runtime adds 128 KiB. `lean.h` does not declare it; Lean's own `lean`
// binary calls it. It returns a boxed unit, which needs no release.
lean_obj_res lean_internal_set_thread_stack_size(size_t size);

// The stack of every thread Lean creates, so of every thread that runs
// config or elaborates it. Lean's default is a gigabyte, and the
// interpreter's stack check fires only once the stack is full: at this size
// a runaway recursion in config ends the process in milliseconds, and the
// elaborator still has ten times the deepest stack it was seen to use
// (`docs/design/lean-runtime.md`). It is set here, not through
// `LEAN_STACK_SIZE_KB` in the process's environment, which every child
// process would inherit. A user can still override it with that variable:
// Lean reads it when its `main` starts, after this.
#define LEAN_THREAD_STACK_SIZE ((size_t)64 << 20)

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

// `Editor.Ffi.threadStackSize : IO USize`. The stack size of the calling
// thread, as the operating system reports it.
lean_obj_res editor_glue_thread_stack_size(void) {
  return lean_io_result_mk_ok(
      lean_box_usize(pthread_get_stacksize_np(pthread_self())));
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

  // Before Lean starts, so that it holds for the first thread Lean creates.
  lean_internal_set_thread_stack_size(LEAN_THREAD_STACK_SIZE);

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
