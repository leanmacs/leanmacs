// The glue of the package `acp`: between Lean's `@[extern]` calling
// convention (`Acp/Real.lean`) and its crate's plain C ABI
// (`rust/src/ffi.rs`).
//
// The package's lakefile compiles it against the toolchain's `lean.h`, with
// every warning an error, and links it beside the core's glue in every
// executable that imports `Acp.Real` (the library `AcpReal`'s
// `moreLinkObjs`). The C functions it calls are in the one Rust archive the
// package-set build generates from the set (docs/design/packages.md, "Rust in
// a package"). It follows the core's conventions (`lean/ffi/glue.c`): a
// string crosses as a pointer and a byte length, borrowed for the call; a
// reply comes back as one record filled in one call, its text copied into a
// Lean string and the crate's buffer handed straight back.

#include <lean/lean.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// The crate's `RawReply`.
typedef struct {
  uint8_t *text;
  size_t text_len;
} acp_raw_reply;

bool acp_ffi_open(uint64_t request, uint64_t child, const uint8_t *cwd,
                  size_t cwd_len, const uint8_t *mcp, size_t mcp_len);
bool acp_ffi_next(uint64_t request, uint64_t session);
bool acp_ffi_prompt(uint64_t request, uint64_t session, const uint8_t *text,
                    size_t len);
bool acp_ffi_cancel_turn(uint64_t request, uint64_t session);
bool acp_ffi_set_mode(uint64_t request, uint64_t session, const uint8_t *id,
                      size_t len);
bool acp_ffi_answer(uint64_t request, uint64_t session, uint64_t ticket,
                    const uint8_t *option, size_t len);
bool acp_ffi_take(uint64_t request, acp_raw_reply *out);
bool acp_ffi_withdraw(uint64_t request);
void acp_ffi_flush(uint64_t request);
void acp_ffi_free(uint8_t *text, size_t len);

// The bytes of a borrowed Lean string, without its terminating NUL.
static const uint8_t *bytes_of(b_lean_obj_arg text) {
  return (const uint8_t *)lean_string_cstr(text);
}

// The byte length of a borrowed Lean string, without its terminating NUL.
static size_t length_of(b_lean_obj_arg text) {
  return lean_string_size(text) - 1;
}

// `Acp.Real.open : UInt64 → UInt64 → @& String → @& String → IO Bool`
lean_obj_res acp_glue_open(uint64_t request, uint64_t child, b_lean_obj_arg cwd,
                           b_lean_obj_arg servers) {
  return lean_io_result_mk_ok(
      lean_box(acp_ffi_open(request, child, bytes_of(cwd), length_of(cwd),
                            bytes_of(servers), length_of(servers))));
}

// `Acp.Real.next : UInt64 → UInt64 → IO Bool`
lean_obj_res acp_glue_next(uint64_t request, uint64_t session) {
  return lean_io_result_mk_ok(lean_box(acp_ffi_next(request, session)));
}

// `Acp.Real.prompt : UInt64 → UInt64 → @& String → IO Bool`
lean_obj_res acp_glue_prompt(uint64_t request, uint64_t session,
                             b_lean_obj_arg text) {
  return lean_io_result_mk_ok(lean_box(
      acp_ffi_prompt(request, session, bytes_of(text), length_of(text))));
}

// `Acp.Real.cancelTurn : UInt64 → UInt64 → IO Bool`
lean_obj_res acp_glue_cancel_turn(uint64_t request, uint64_t session) {
  return lean_io_result_mk_ok(lean_box(acp_ffi_cancel_turn(request, session)));
}

// `Acp.Real.setMode : UInt64 → UInt64 → @& String → IO Bool`
lean_obj_res acp_glue_set_mode(uint64_t request, uint64_t session,
                               b_lean_obj_arg mode) {
  return lean_io_result_mk_ok(lean_box(
      acp_ffi_set_mode(request, session, bytes_of(mode), length_of(mode))));
}

// `Acp.Real.answer : UInt64 → UInt64 → UInt64 → @& String → IO Bool`
lean_obj_res acp_glue_answer(uint64_t request, uint64_t session,
                             uint64_t ticket, b_lean_obj_arg option) {
  return lean_io_result_mk_ok(lean_box(acp_ffi_answer(
      request, session, ticket, bytes_of(option), length_of(option))));
}

// `Acp.Real.take : UInt64 → IO (Option String)`: the reply's text.
lean_obj_res acp_glue_take(uint64_t request) {
  acp_raw_reply raw;
  if (!acp_ffi_take(request, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  acp_ffi_free(raw.text, raw.text_len);
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, text);
  return lean_io_result_mk_ok(some);
}

// `Acp.Real.withdraw : UInt64 → IO Bool`
lean_obj_res acp_glue_withdraw(uint64_t request) {
  return lean_io_result_mk_ok(lean_box(acp_ffi_withdraw(request)));
}

// `Acp.Real.flush : UInt64 → IO Unit`
lean_obj_res acp_glue_flush(uint64_t request) {
  acp_ffi_flush(request);
  return lean_io_result_mk_ok(lean_box(0));
}
