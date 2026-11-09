// C shim between Rust and Lean.
//
// lean.h is mostly `static inline` helpers (strings, IO results, refcounts),
// which Rust can't call directly. This file wraps them in a small plain-C API
// for Rust, and implements the `@[extern]` host primitives that Lean calls by
// forwarding to Rust.

#include <lean/lean.h>
#include <stdlib.h>
#include <string.h>

// ---- Lean side (exported from EditorHost.lean / generated module init) ----

lean_object *EDITOR_MODULE_INIT(uint8_t builtin, lean_object *world);

lean_object *editor_session_new(lean_object *sysroot, lean_object *olean_dir,
                                lean_object *world);
// Exported Lean functions take all arguments owned.
lean_object *editor_session_eval(lean_object *s, lean_object *src,
                                 lean_object *world);
lean_object *editor_session_run(lean_object *s, lean_object *name,
                                lean_object *world);
lean_object *editor_session_set_chunk(lean_object *s, lean_object *name,
                                      lean_object *src, lean_object *world);
lean_object *editor_session_remove_chunk(lean_object *s, lean_object *name,
                                         lean_object *world);
lean_object *editor_io_error_to_string(lean_object *err);
uint8_t editor_result_ok(lean_object *r);

// From libleanshared (not declared in lean.h): initializes the `Lean` package.
void lean_initialize(void);
void lean_initialize_runtime_module(void);
lean_object *editor_result_output(lean_object *r);

// ---- Rust side (implemented in src/main.rs) ----

void rust_host_insert(const char *ptr, size_t len);
void rust_host_buffer_text(const char **ptr, size_t *len);
void rust_host_message(const char *ptr, size_t len);

// ---- @[extern] host primitives called by Lean ----

lean_obj_res editor_host_insert(b_lean_obj_arg s, lean_obj_arg world) {
  rust_host_insert(lean_string_cstr(s), lean_string_size(s) - 1);
  return lean_io_result_mk_ok(lean_box(0));
}

lean_obj_res editor_host_buffer_text(lean_obj_arg world) {
  const char *ptr;
  size_t len;
  rust_host_buffer_text(&ptr, &len);
  return lean_io_result_mk_ok(lean_mk_string_from_bytes(ptr, len));
}

lean_obj_res editor_host_message(b_lean_obj_arg s, lean_obj_arg world) {
  rust_host_message(lean_string_cstr(s), lean_string_size(s) - 1);
  return lean_io_result_mk_ok(lean_box(0));
}

// ---- Plain-C API used by Rust ----

static char *dup_lean_string(b_lean_obj_arg s) {
  size_t len = lean_string_size(s); // includes NUL
  char *out = malloc(len);
  memcpy(out, lean_string_cstr(s), len);
  return out;
}

// Renders an IO error result to a malloc'd string and consumes `res`.
static char *io_error_string(lean_object *res) {
  lean_object *err = lean_io_result_get_error(res);
  lean_inc(err);
  lean_dec(res);
  lean_object *msg = editor_io_error_to_string(err); // consumes err
  char *out = dup_lean_string(msg);
  lean_dec(msg);
  return out;
}

// Returns NULL on success, or a malloc'd error string.
char *shim_init(void) {
  lean_initialize_runtime_module();
  lean_initialize(); // the `Lean` package: elaborator, interpreter, ...
  lean_set_panic_messages(true);
  lean_object *res = EDITOR_MODULE_INIT(1, lean_io_mk_world());
  if (lean_io_result_is_error(res)) {
    return io_error_string(res);
  }
  lean_dec(res);
  lean_io_mark_end_initialization();
  lean_init_task_manager(); // elaborator uses tasks/promises
  return NULL;
}

// Returns a session (owned) or NULL with *err set to a malloc'd string.
lean_object *shim_session_new(const char *sysroot, const char *olean_dir,
                              char **err) {
  lean_object *res = editor_session_new(
      lean_mk_string(sysroot), lean_mk_string(olean_dir), lean_io_mk_world());
  if (lean_io_result_is_error(res)) {
    *err = io_error_string(res);
    return NULL;
  }
  lean_object *s = lean_io_result_get_value(res);
  lean_inc(s);
  lean_dec(res);
  *err = NULL;
  return s;
}

void shim_session_free(lean_object *s) { lean_dec(s); }

// Unpacks an `IO EvalResult` into (ok, malloc'd output). Consumes `res`.
static int unpack_result(lean_object *res, char **out) {
  if (lean_io_result_is_error(res)) {
    *out = io_error_string(res);
    return 0;
  }
  lean_object *r = lean_io_result_get_value(res);
  lean_inc(r); // one ref per (consuming) accessor call
  lean_inc(r);
  int ok = editor_result_ok(r);
  lean_object *output = editor_result_output(r);
  *out = dup_lean_string(output);
  lean_dec(output);
  lean_dec(res);
  return ok;
}

// `s` stays owned by the caller; the Lean call consumes one reference.
int shim_session_eval(lean_object *s, const char *src, char **out) {
  lean_inc(s);
  return unpack_result(
      editor_session_eval(s, lean_mk_string(src), lean_io_mk_world()), out);
}

int shim_session_run(lean_object *s, const char *name, char **out) {
  lean_inc(s);
  return unpack_result(
      editor_session_run(s, lean_mk_string(name), lean_io_mk_world()), out);
}

int shim_session_set_chunk(lean_object *s, const char *name, const char *src,
                           char **out) {
  lean_inc(s);
  return unpack_result(editor_session_set_chunk(s, lean_mk_string(name),
                                                lean_mk_string(src),
                                                lean_io_mk_world()),
                       out);
}

int shim_session_remove_chunk(lean_object *s, const char *name, char **out) {
  lean_inc(s);
  return unpack_result(editor_session_remove_chunk(s, lean_mk_string(name),
                                                   lean_io_mk_world()),
                       out);
}

void shim_free(char *p) { free(p); }
