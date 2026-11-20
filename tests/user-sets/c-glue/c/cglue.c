/* The C side of the fixture package `c-glue`: what `CGlue.answer` binds. */
#include <lean/lean.h>

uint32_t leanmacs_cglue_answer(lean_obj_arg unit) {
  (void)unit;
  return 42;
}
