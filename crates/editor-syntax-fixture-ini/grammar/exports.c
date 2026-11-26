// The fixture library's exports beside the generated grammar's
// `tree_sitter_ini` (src/parser.c). Each is a fixture for one property of
// the registration contract, not a grammar to use (../README.md).

#include "tree_sitter/parser.h"

#define FIXTURE_EXPORT __attribute__((visibility("default")))

const TSLanguage *tree_sitter_ini(void);

// The INI grammar under a compiled-in grammar's name: a library that
// overrides `json`.
FIXTURE_EXPORT const TSLanguage *tree_sitter_json(void) {
  return tree_sitter_ini();
}

// A language of ABI 0, below any version the parsing library accepts. Every
// field is zero; only the ABI version is ever read, and it is refused before
// any parser is made.
static const TSLanguage abi_0;

FIXTURE_EXPORT const TSLanguage *tree_sitter_abi_0(void) { return &abi_0; }
