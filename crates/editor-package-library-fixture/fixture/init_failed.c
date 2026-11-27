// A package library whose init fails: it answers 7, a status no library
// answers, leaving the table unwritten (../src/lib.rs). Its declaration says
// interface 1 and today's runtime, so the core calls its init.

#include "editor_package_runtime.h"

#define FIXTURE_EXPORT __attribute__((visibility("default")))

EDITOR_PACKAGE_DECLARE(1, buffer_free);

FIXTURE_EXPORT uint32_t editor_package_init(const size_t *runtime,
                                            const void **table) {
  (void)runtime;
  (void)table;
  return 7;
}
