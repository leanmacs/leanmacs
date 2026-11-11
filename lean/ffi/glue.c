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
#include <stdbool.h>

// The Rust library.
bool editor_ffi_is_main_thread(void);

// `Editor.Ffi.isMainThread : IO Bool`
lean_obj_res editor_glue_is_main_thread(void) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_is_main_thread()));
}
