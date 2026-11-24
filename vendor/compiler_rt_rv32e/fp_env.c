#include "fp_mode.h"

/* WebAssembly arithmetic uses round-to-nearest, ties-to-even, and does not
 * expose IEEE exception flags. E902 has no hardware floating point state. */
CRT_FE_ROUND_MODE __fe_getround(void) { return CRT_FE_TONEAREST; }
int __fe_raise_inexact(void) { return 0; }
