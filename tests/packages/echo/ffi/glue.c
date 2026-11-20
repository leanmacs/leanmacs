// The glue of the fixture package `echo`: between Lean's `@[extern]` calling
// convention (`Echo/Real.lean`) and its crate's plain C ABI
// (`rust/src/ffi.rs`).
//
// The package's lakefile compiles it against the toolchain's `lean.h`, with
// every warning an error, and links it beside the core's glue in every
// executable that imports `Echo.Real` (the library `EchoReal`'s
// `moreLinkObjs`). The C functions it calls are in the one Rust archive the
// package-set build generates from the set (docs/design/packages.md, "Rust in
// a package"). It follows the core's conventions (`lean/ffi/glue.c`): a
// string crosses as a pointer and a byte length, borrowed for the call; a
// reply comes back as one record filled in one call, its text copied into a
// Lean string and handed straight back.

#include <lean/lean.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// The crate's `RawReply`.
typedef struct {
  uint8_t *text;
  size_t text_len;
  uint32_t checksum;
} echo_raw_reply;

bool echo_ffi_start(uint64_t id, const uint8_t *text, size_t len);
bool echo_ffi_cancel(uint64_t id);
bool echo_ffi_take(uint64_t id, echo_raw_reply *out);
void echo_ffi_free(uint8_t *text, size_t len);

// `Echo.Real.start : UInt64 → @& String → IO Bool`
lean_obj_res echo_glue_start(uint64_t id, b_lean_obj_arg text) {
  return lean_io_result_mk_ok(
      lean_box(echo_ffi_start(id, (const uint8_t *)lean_string_cstr(text),
                              lean_string_size(text) - 1)));
}

// `Echo.Real.cancel : UInt64 → IO Bool`
lean_obj_res echo_glue_cancel(uint64_t id) {
  return lean_io_result_mk_ok(lean_box(echo_ffi_cancel(id)));
}

// `Echo.Real.takeRaw : UInt64 → IO (Option (String × UInt32))`: the text and
// its checksum.
lean_obj_res echo_glue_take(uint64_t id) {
  echo_raw_reply raw;
  if (!echo_ffi_take(id, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  echo_ffi_free(raw.text, raw.text_len);
  lean_object *pair = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(pair, 0, text);
  lean_ctor_set(pair, 1, lean_box_uint32(raw.checksum));
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, pair);
  return lean_io_result_mk_ok(some);
}
