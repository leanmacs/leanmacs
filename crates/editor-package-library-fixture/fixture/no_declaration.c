// A package library that exports an init and no declaration, as one built
// before the declaration was: the core refuses it before it calls the init,
// which would write a table and answer 0 (../src/lib.rs).

#include "editor_package_runtime.h"

#define FIXTURE_EXPORT __attribute__((visibility("default")))

static const size_t the_table = sizeof(size_t);

FIXTURE_EXPORT uint32_t editor_package_init(const EditorPackageRuntime *runtime,
                                            const void **table) {
  (void)runtime;
  *table = &the_table;
  return EDITOR_PACKAGE_INIT_LOADED;
}
