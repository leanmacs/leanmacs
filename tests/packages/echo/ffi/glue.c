// The glue of the fixture package `echo`: between Lean's `@[extern]` calling
// convention (`Echo/Real.lean`) and its library's plain C ABI
// (`rust/src/ffi.rs`).
//
// The package's lakefile compiles it against the toolchain's `lean.h`, with
// every warning an error, and links it beside the core's glue in every
// executable that imports `Echo.Real` (the library `EchoReal`'s
// `moreLinkObjs`). Echo's crate is not linked: it is a library of its own,
// which the glue asks the core to load (`editor_ffi_package_load`, in the
// core's Rust archive) from the path the lakefile compiled in
// (`ECHO_LIBRARY`), when `Echo.Real`'s initialiser runs, before Lean's
// `main`. The core opens it, calls its init with the package runtime and
// hands back its table (`echo_table`), through which every `echo_glue_*`
// function forwards (docs/design/packages.md, "A library loaded when the
// editor runs, as built"). Before a load, each answers false or `none`.
//
// It follows the core's conventions (`lean/ffi/glue.c`): a string crosses as
// a pointer and a byte length, borrowed for the call; a reply comes back as
// one record filled in one call, its text copied into a Lean string and
// handed straight back, through the table's `free`. The library is written
// against the package wrapper (`editor-package`), whose types each call
// crosses as: a text is its `Bytes`, `{ bytes, len }` by value; a reply's
// text is its `Lent`, `{ bytes, len }`, handed back by value to `free`; a
// reply's place is its `Out`, a plain pointer; and the table is its
// `Table`, the size first, then echo's functions.

#include <lean/lean.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifndef ECHO_LIBRARY
#error "the lakefile compiles the library's path in as ECHO_LIBRARY"
#endif

// The wrapper's `Bytes`: bytes lent for the call.
typedef struct {
  const uint8_t *bytes;
  size_t len;
} echo_bytes;

// The wrapper's `Lent`: a buffer the library lent, handed back to `free`.
typedef struct {
  uint8_t *bytes;
  size_t len;
} echo_lent;

// The library's `RawReply`.
typedef struct {
  echo_lent text;
  uint32_t checksum;
} echo_raw_reply;

// The wrapper's `Table` of the library's `EchoFunctions`, member for member.
typedef struct {
  size_t size;
  bool (*start)(uint64_t id, echo_bytes text);
  bool (*cancel)(uint64_t id);
  bool (*take)(uint64_t id, echo_raw_reply *out);
  void (*flush)(uint64_t id);
  bool (*attach)(uint64_t request, uint64_t child);
  bool (*attach_take)(uint64_t request, echo_raw_reply *out);
  void (*free)(echo_lent text);
} echo_table;

// The core's loader of a package's library (`editor-ffi`'s
// `package_library.rs`): 0 with the table written, or a refusal, 1 to 5.
uint32_t editor_ffi_package_load(const uint8_t *path, size_t len,
                                 const void **table);

// The table of the library loaded, or none yet: set once, by a load, and
// read by every call, from any thread.
static _Atomic(const echo_table *) loaded = NULL;

// The table, if the library was loaded.
static const echo_table *echo_loaded(void) {
  return atomic_load_explicit(&loaded, memory_order_acquire);
}

// `Echo.Real.library : IO String`: the path the lakefile compiled in.
lean_obj_res echo_glue_library(void) {
  return lean_io_result_mk_ok(lean_mk_string(ECHO_LIBRARY));
}

// `Echo.Real.loadFrom : @& String → IO UInt32`: asks the core to load the
// library at `path`, keeps its table on 0, and answers the core's status.
lean_obj_res echo_glue_load(b_lean_obj_arg path) {
  const void *table = NULL;
  uint32_t status =
      editor_ffi_package_load((const uint8_t *)lean_string_cstr(path),
                              lean_string_size(path) - 1, &table);
  if (status == 0) {
    atomic_store_explicit(&loaded, (const echo_table *)table,
                          memory_order_release);
  }
  return lean_io_result_mk_ok(lean_box_uint32(status));
}

// `Echo.Real.start : UInt64 → @& String → IO Bool`
lean_obj_res echo_glue_start(uint64_t id, b_lean_obj_arg text) {
  const echo_table *table = echo_loaded();
  echo_bytes bytes = {.bytes = (const uint8_t *)lean_string_cstr(text),
                      .len = lean_string_size(text) - 1};
  return lean_io_result_mk_ok(
      lean_box(table != NULL && table->start(id, bytes)));
}

// `Echo.Real.cancel : UInt64 → IO Bool`
lean_obj_res echo_glue_cancel(uint64_t id) {
  const echo_table *table = echo_loaded();
  return lean_io_result_mk_ok(lean_box(table != NULL && table->cancel(id)));
}

// `Echo.Real.flush : UInt64 → IO Unit`
lean_obj_res echo_glue_flush(uint64_t id) {
  const echo_table *table = echo_loaded();
  if (table != NULL) {
    table->flush(id);
  }
  return lean_io_result_mk_ok(lean_box(0));
}

// A reply taken through `take`, as `Option (String × UInt32)`: its text
// copied into a Lean string and handed back through the table's `free`.
static lean_obj_res echo_reply(const echo_table *table, echo_raw_reply raw) {
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text.bytes, raw.text.len);
  table->free(raw.text);
  lean_object *pair = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(pair, 0, text);
  lean_ctor_set(pair, 1, lean_box_uint32(raw.checksum));
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, pair);
  return some;
}

// `Echo.Real.takeRaw : UInt64 → IO (Option (String × UInt32))`: the text and
// its checksum.
lean_obj_res echo_glue_take(uint64_t id) {
  const echo_table *table = echo_loaded();
  echo_raw_reply raw;
  if (table == NULL || !table->take(id, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  return lean_io_result_mk_ok(echo_reply(table, raw));
}

// The library takes over a streaming child a Lean job opened in the core's
// process service, through the package runtime, and reads it in Rust as a
// request of its service (`rust/src/attach.rs`).

// `Echo.Real.attach : UInt64 → UInt64 → IO Bool`
lean_obj_res echo_glue_attach(uint64_t request, uint64_t child) {
  const echo_table *table = echo_loaded();
  return lean_io_result_mk_ok(
      lean_box(table != NULL && table->attach(request, child)));
}

// `Echo.Real.attachTake : UInt64 → IO (Option (String × UInt32))`: the lines
// read, joined by line feeds, and how many pulls it took.
lean_obj_res echo_glue_attach_take(uint64_t request) {
  const echo_table *table = echo_loaded();
  echo_raw_reply raw;
  if (table == NULL || !table->attach_take(request, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  return lean_io_result_mk_ok(echo_reply(table, raw));
}
