// A package library whose declaration's `size` ends at the end of
// `runtime`, before `interface`, though every member is written: a reader
// by the members its size covers reads `runtime` and reads `interface` as
// 0, never the 1 written past the size. The core refuses it as declaring
// nothing before it calls the init, which would write a table and answer 0
// (../src/lib.rs).

#include <stddef.h>
#include <stdint.h>

#define FIXTURE_EXPORT __attribute__((visibility("default")))

// The declaration as the header lays it out, written by hand so that its
// `size` can end before `interface`.
struct short_declaration {
  size_t size;
  size_t runtime;
  uint32_t interface;
};

FIXTURE_EXPORT const struct short_declaration editor_package_declaration = {
    offsetof(struct short_declaration, interface), 88, 1};

static const size_t the_table = sizeof(size_t);

FIXTURE_EXPORT uint32_t editor_package_init(const void *runtime,
                                            const void **table) {
  (void)runtime;
  *table = &the_table;
  return 0;
}
