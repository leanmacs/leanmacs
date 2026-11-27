// A package library built against the generated header of the package
// runtime: it checks the runtime has every member it calls, registers the
// service "current" and writes a table that completes, posts an event, and
// lends a buffer and hands it back twice (../src/lib.rs). It is the one
// place the generated header is compiled by a C compiler and run against
// the Rust runtime.

#include "editor_package_runtime.h"

#define FIXTURE_EXPORT __attribute__((visibility("default")))

// The library's table: its size, its service's id and its functions.
struct current_table {
  size_t size;
  uint64_t service;
  bool (*fire)(uint64_t request);
  bool (*post)(uint64_t code, const uint8_t *text, size_t len);
  void (*lend_twice)(bool *first, bool *second);
};

static const EditorPackageRuntime *the_runtime;
static struct current_table the_table;

// Completes `request` from the library's service.
static bool fire(uint64_t request) {
  return the_runtime->complete(the_runtime, the_table.service, request);
}

// Posts an event of `code` and the `len` bytes at `text` from the
// library's service.
static bool post(uint64_t code, const uint8_t *text, size_t len) {
  return the_runtime->post_event(the_runtime, the_table.service, code, text,
                                 len);
}

// Lends a buffer and hands it back twice, answering both hand-backs.
static void lend_twice(bool *first, bool *second) {
  static const char bytes[] = "lent";
  EditorRawBuffer lent;
  the_runtime->buffer_lend(the_runtime, (const uint8_t *)bytes,
                           sizeof(bytes) - 1, &lent);
  *first = the_runtime->buffer_free(the_runtime, lent.bytes, lent.len);
  *second = the_runtime->buffer_free(the_runtime, lent.bytes, lent.len);
}

FIXTURE_EXPORT uint32_t editor_package_init(const EditorPackageRuntime *runtime,
                                            const void **table) {
  if (runtime == NULL || !EDITOR_PACKAGE_RUNTIME_HAS(runtime, buffer_free)) {
    return EDITOR_PACKAGE_INIT_RUNTIME_TOO_SMALL;
  }
  static const char name[] = "current";
  the_runtime = runtime;
  the_table.size = sizeof(struct current_table);
  the_table.service = runtime->register_service(runtime, (const uint8_t *)name,
                                                sizeof(name) - 1);
  the_table.fire = fire;
  the_table.post = post;
  the_table.lend_twice = lend_twice;
  *table = &the_table;
  return EDITOR_PACKAGE_INIT_LOADED;
}

// The library's declaration: interface 1, and the runtime through
// `buffer_free`, the last member it calls.
EDITOR_PACKAGE_DECLARE(1, buffer_free);

// The init has the type the header gives it.
__attribute__((unused)) static const EditorPackageInit init_type_checked =
    editor_package_init;
