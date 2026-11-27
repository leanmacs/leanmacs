// A package library built for a runtime one member longer than today's: its
// declaration says it needs that larger runtime, so the core refuses it
// before it calls the init, which would write a table and answer 0
// (../src/lib.rs).

#include "editor_package_runtime.h"

#define FIXTURE_EXPORT __attribute__((visibility("default")))

// One function pointer past today's runtime, and interface 1.
FIXTURE_EXPORT const EditorPackageDeclaration editor_package_declaration = {
    sizeof(EditorPackageDeclaration),
    sizeof(EditorPackageRuntime) + sizeof(void (*)(void)), 1};

static const size_t the_table = sizeof(size_t);

FIXTURE_EXPORT uint32_t editor_package_init(const EditorPackageRuntime *runtime,
                                            const void **table) {
  (void)runtime;
  *table = &the_table;
  return EDITOR_PACKAGE_INIT_LOADED;
}
