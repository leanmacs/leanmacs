// A package library whose init fails: it answers 7, a status no library
// answers, leaving the table unwritten (../src/lib.rs).

#include <stddef.h>
#include <stdint.h>

#define FIXTURE_EXPORT __attribute__((visibility("default")))

FIXTURE_EXPORT uint32_t editor_package_init(const size_t *runtime,
                                            const void **table) {
  (void)runtime;
  (void)table;
  return 7;
}
