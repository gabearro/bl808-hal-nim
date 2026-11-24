# RV32E compiler-rt subset

This directory contains only the compiler-rt floating point and integer
helpers needed by `src/bl808/wasm_lp_softfloat.nim`. The files were copied
from the compiler-rt tree bundled with Emscripten 7.0.0 on 2026-11-22.
`LICENSE.TXT` is the upstream license. All helpers are compiled for
`rv32emc_zicsr/ilp32e`; no host or RV32I binary object is linked into LP.

Keep this list synchronized with undefined symbols from an LP full-interpreter
build. The full guest semantics must remain in `src/cps/wasm/runtime.nim`.
