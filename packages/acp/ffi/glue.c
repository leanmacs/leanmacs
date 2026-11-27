// The glue of the package `acp`: between Lean's `@[extern]` calling
// convention (`Acp/Real.lean`) and its library's plain C ABI
// (`rust/src/ffi.rs`).
//
// The package's lakefile compiles it against the toolchain's `lean.h`, with
// every warning an error, and links it beside the core's glue in every
// executable that imports `Acp.Real` (the library `AcpReal`'s
// `moreLinkObjs`). acp's crate is not linked: it is a library of its own,
// which the package-set build stages beside every editor it links and
// records in `<executable>.libraries`. No path is compiled in here:
// `Acp.Real`'s initialiser reads the staged path from that record when it
// runs, before Lean's `main`, and hands it to `acp_glue_load_library` with
// the interface version this glue was compiled for (`ACP_INTERFACE`), which
// asks the core to load it (`editor_ffi_package_load`, in the core's Rust
// archive). The core reads the library's declaration, refuses one of
// another interface or a newer runtime, calls its init with the package
// runtime and hands back its table (`acp_table`), through which every other
// `acp_glue_*` function forwards (docs/design/packages.md, "A package's
// library, staged and loaded, as built"). Before a load, each answers false
// or `none`. `acp_glue_load` is the session's load (`session/load`), which
// forwards through the table's `load`; the library's own load is
// `acp_glue_load_library`.
//
// It follows the core's conventions (`lean/ffi/glue.c`): a string crosses as
// a pointer and a byte length, borrowed for the call; a reply comes back as
// one record filled in one call, its text copied into a Lean string and
// handed straight back, through the table's `free`. The library is written
// against the package wrapper (`editor-package`), whose types each call
// crosses as: a text is its `Bytes`, `{ bytes, len }` by value; a reply's
// text is its `Lent`, `{ bytes, len }`, handed back by value to `free`; a
// reply's place is its `Out`, a plain pointer; and the table is its
// `Table`, the size first, then acp's functions.

#include <lean/lean.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// The wrapper's `Bytes`: bytes lent for the call.
typedef struct {
  const uint8_t *bytes;
  size_t len;
} acp_bytes;

// The wrapper's `Lent`: a buffer the library lent, handed back to `free`.
typedef struct {
  uint8_t *bytes;
  size_t len;
} acp_lent;

// The library's `RawReply`.
typedef struct {
  acp_lent text;
} acp_raw_reply;

// The wrapper's `Table` of the library's `AcpFunctions`, member for member.
typedef struct {
  size_t size;
  bool (*open)(uint64_t request, uint64_t child, acp_bytes cwd, acp_bytes mcp);
  bool (*load)(uint64_t request, uint64_t child, acp_bytes cwd, acp_bytes mcp,
               acp_bytes session);
  bool (*next)(uint64_t request, uint64_t session);
  bool (*prompt)(uint64_t request, uint64_t session, acp_bytes text);
  bool (*cancel_turn)(uint64_t request, uint64_t session);
  bool (*set_mode)(uint64_t request, uint64_t session, acp_bytes id);
  bool (*answer)(uint64_t request, uint64_t session, uint64_t ticket,
                 acp_bytes option);
  bool (*take)(uint64_t request, acp_raw_reply *out);
  bool (*withdraw)(uint64_t request);
  void (*flush)(uint64_t request);
  void (*free)(acp_lent text);
} acp_table;

// The interface version this glue was compiled for: the shape of
// `acp_table`, which the library declares too (`package! { interface 1; …
// }`, `rust/src/ffi.rs`). A change to the table's shape is a new version,
// here and in the library together.
#define ACP_INTERFACE 1u

// The core's loader of a package's library (`editor-ffi`'s
// `package_library.rs`): 0 with the table written, or a refusal, 1 to 8,
// with the two numbers it compared written to `versions` for a newer
// runtime (7) or another interface (8).
uint32_t editor_ffi_package_load(const uint8_t *path, size_t len,
                                 uint32_t interface, const void **table,
                                 uint64_t *versions);

// The table of the library loaded, or none yet: set once, by a load, and
// read by every call, from any thread.
static _Atomic(const acp_table *) loaded = NULL;

// The table, if the library was loaded.
static const acp_table *acp_loaded(void) {
  return atomic_load_explicit(&loaded, memory_order_acquire);
}

// A borrowed Lean string as the wrapper's `Bytes`, without its terminating
// NUL.
static acp_bytes bytes_of(b_lean_obj_arg text) {
  acp_bytes bytes = {.bytes = (const uint8_t *)lean_string_cstr(text),
                     .len = lean_string_size(text) - 1};
  return bytes;
}

// `Acp.Real.interface : IO UInt32`: the version this glue was compiled for.
lean_obj_res acp_glue_interface(void) {
  return lean_io_result_mk_ok(lean_box_uint32(ACP_INTERFACE));
}

// `Acp.Real.loadLibraryFrom : @& String → UInt32 → IO (UInt32 × UInt64 ×
// UInt64)`: asks the core to load the library at `path` for a glue of
// `interface`, keeps its table on 0, and answers the core's status and the
// two numbers it wrote, 0 and 0 when it wrote none.
lean_obj_res acp_glue_load_library(b_lean_obj_arg path, uint32_t interface) {
  const void *table = NULL;
  uint64_t versions[2] = {0, 0};
  uint32_t status = editor_ffi_package_load(
      (const uint8_t *)lean_string_cstr(path), lean_string_size(path) - 1,
      interface, &table, versions);
  if (status == 0) {
    atomic_store_explicit(&loaded, (const acp_table *)table,
                          memory_order_release);
  }
  lean_object *numbers = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(numbers, 0, lean_box_uint64(versions[0]));
  lean_ctor_set(numbers, 1, lean_box_uint64(versions[1]));
  lean_object *answer = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(answer, 0, lean_box_uint32(status));
  lean_ctor_set(answer, 1, numbers);
  return lean_io_result_mk_ok(answer);
}

// `Acp.Real.open : UInt64 → UInt64 → @& String → @& String → IO Bool`
lean_obj_res acp_glue_open(uint64_t request, uint64_t child, b_lean_obj_arg cwd,
                           b_lean_obj_arg servers) {
  const acp_table *table = acp_loaded();
  return lean_io_result_mk_ok(
      lean_box(table != NULL &&
               table->open(request, child, bytes_of(cwd), bytes_of(servers))));
}

// `Acp.Real.load : UInt64 → UInt64 → @& String → @& String → @& String →
// IO Bool`: the open's arguments, then the agent's id of the session to load;
// through the table's `load`.
lean_obj_res acp_glue_load(uint64_t request, uint64_t child, b_lean_obj_arg cwd,
                           b_lean_obj_arg servers, b_lean_obj_arg session) {
  const acp_table *table = acp_loaded();
  return lean_io_result_mk_ok(lean_box(
      table != NULL && table->load(request, child, bytes_of(cwd),
                                   bytes_of(servers), bytes_of(session))));
}

// `Acp.Real.next : UInt64 → UInt64 → IO Bool`
lean_obj_res acp_glue_next(uint64_t request, uint64_t session) {
  const acp_table *table = acp_loaded();
  return lean_io_result_mk_ok(
      lean_box(table != NULL && table->next(request, session)));
}

// `Acp.Real.prompt : UInt64 → UInt64 → @& String → IO Bool`
lean_obj_res acp_glue_prompt(uint64_t request, uint64_t session,
                             b_lean_obj_arg text) {
  const acp_table *table = acp_loaded();
  return lean_io_result_mk_ok(lean_box(
      table != NULL && table->prompt(request, session, bytes_of(text))));
}

// `Acp.Real.cancelTurn : UInt64 → UInt64 → IO Bool`
lean_obj_res acp_glue_cancel_turn(uint64_t request, uint64_t session) {
  const acp_table *table = acp_loaded();
  return lean_io_result_mk_ok(
      lean_box(table != NULL && table->cancel_turn(request, session)));
}

// `Acp.Real.setMode : UInt64 → UInt64 → @& String → IO Bool`
lean_obj_res acp_glue_set_mode(uint64_t request, uint64_t session,
                               b_lean_obj_arg mode) {
  const acp_table *table = acp_loaded();
  return lean_io_result_mk_ok(lean_box(
      table != NULL && table->set_mode(request, session, bytes_of(mode))));
}

// `Acp.Real.answer : UInt64 → UInt64 → UInt64 → @& String → IO Bool`
lean_obj_res acp_glue_answer(uint64_t request, uint64_t session,
                             uint64_t ticket, b_lean_obj_arg option) {
  const acp_table *table = acp_loaded();
  return lean_io_result_mk_ok(
      lean_box(table != NULL &&
               table->answer(request, session, ticket, bytes_of(option))));
}

// `Acp.Real.take : UInt64 → IO (Option String)`: the reply's text, copied
// into a Lean string and handed back through the table's `free`.
lean_obj_res acp_glue_take(uint64_t request) {
  const acp_table *table = acp_loaded();
  acp_raw_reply raw;
  if (table == NULL || !table->take(request, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text.bytes, raw.text.len);
  table->free(raw.text);
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, text);
  return lean_io_result_mk_ok(some);
}

// `Acp.Real.withdraw : UInt64 → IO Bool`
lean_obj_res acp_glue_withdraw(uint64_t request) {
  const acp_table *table = acp_loaded();
  return lean_io_result_mk_ok(
      lean_box(table != NULL && table->withdraw(request)));
}

// `Acp.Real.flush : UInt64 → IO Unit`
lean_obj_res acp_glue_flush(uint64_t request) {
  const acp_table *table = acp_loaded();
  if (table != NULL) {
    table->flush(request);
  }
  return lean_io_result_mk_ok(lean_box(0));
}
