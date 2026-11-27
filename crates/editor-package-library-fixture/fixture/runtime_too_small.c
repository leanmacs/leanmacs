// A package library whose init requires a larger package runtime than any
// core hands it: it reads the runtime's size, its first member, and answers
// 1, the runtime too small, leaving the table unwritten (../src/lib.rs).

#include <stddef.h>
#include <stdint.h>

#define FIXTURE_EXPORT __attribute__((visibility("default")))

// No core's runtime is `SIZE_MAX` bytes, so every runtime is too small.
FIXTURE_EXPORT uint32_t editor_package_init(const size_t *runtime,
                                            const void **table) {
  (void)table;
  if (runtime == NULL || *runtime < SIZE_MAX) {
    return 1;
  }
  return 5;
}
