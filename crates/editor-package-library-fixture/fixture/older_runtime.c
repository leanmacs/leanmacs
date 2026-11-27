// A package library built when the package runtime ended at `complete`: it
// declares that smaller runtime itself, as the header read then, checks the
// runtime it is handed is at least that large, registers the service
// "older" and writes a table whose `fire` completes a request through the
// older view (../src/lib.rs). It declares that smaller runtime by hand, as
// the declaration read when it was built. It runs on any later, larger
// runtime.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define FIXTURE_EXPORT __attribute__((visibility("default")))

// The runtime as the header declared it when it ended at `complete`.
struct older_runtime {
  size_t size;
  void *private_members;
  uint64_t (*register_service)(const struct older_runtime *runtime,
                               const uint8_t *name, size_t len);
  bool (*complete)(const struct older_runtime *runtime, uint64_t service,
                   uint64_t request);
};

// The declaration as a library declares it by hand, against no header: its
// own size, the runtime through `complete`, and interface 1.
struct older_declaration {
  size_t size;
  size_t runtime;
  uint32_t interface;
};

FIXTURE_EXPORT const struct older_declaration editor_package_declaration = {
    sizeof(struct older_declaration), sizeof(struct older_runtime), 1};

// The library's table: its size, its service's id and `fire`.
struct older_table {
  size_t size;
  uint64_t service;
  bool (*fire)(uint64_t request);
};

static const struct older_runtime *the_runtime;
static struct older_table the_table;

// Completes `request` from the library's service, through the older view.
static bool fire(uint64_t request) {
  return the_runtime->complete(the_runtime, the_table.service, request);
}

FIXTURE_EXPORT uint32_t editor_package_init(const struct older_runtime *runtime,
                                            const void **table) {
  if (runtime == NULL || runtime->size < sizeof(struct older_runtime)) {
    return 1;
  }
  static const char name[] = "older";
  the_runtime = runtime;
  the_table.size = sizeof(struct older_table);
  the_table.service = runtime->register_service(runtime, (const uint8_t *)name,
                                                sizeof(name) - 1);
  the_table.fire = fire;
  *table = &the_table;
  return 0;
}
