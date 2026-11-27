# Proof-carrying WebAssembly

zkbuild is an experimental prover and verifier for bounded WASM profiles.
The host tool and target verifier are Nim. Lean specifies separate proof
obligations under [formal/zkbuild](../formal/zkbuild/). The repository's
normal WASM validation remains the admission path for general modules.

## Available claims

| Claim | What it binds |
| --- | --- |
| `validate` | The exact bytes and length of an ordinary WASM module in the bounded profile. |
| `validate-slots` | A fixed-slot WASM encoding with up to sixteen instruction slots and the named export `run`. |
| `compile` | The exact fixed-slot WASM input and the native bytes produced by the restricted RV32 emitter. |
| `compile-bytes` | The exact ordinary-profile WASM bytes, length, and 144-byte RV32 output of its restricted emitter. This path admits up to sixteen non-`nop` operations. |

The ordinary profile contains one `(i32, i32) -> i32` function and a
three-byte ASCII export. It accepts up to 120 instruction bytes and
156 module bytes. Instructions are `nop`, `local.get` of either
parameter, signed `i32.const` with one to five LEB128 bytes, and i32 add,
subtract, multiply, AND, OR, and XOR. The operand stack is bounded at
eight entries. The profile has no branches, calls, imports, memory, globals,
tables, or start function.

Each claim has its own verification key. The native claims bind a
restricted two-argument RV32 function. The claim statements start at the
submitted WASM binary and cover the operations above. Source-language
provenance and general JIT correctness lie outside those statements.
[Proof code](../src/cps/zk/) ·
[Target loader](../src/bl808/wasm_verified_loader.nim).

## Build and verify

```sh
make zkbuild
make zkbuild-test
make zkbuild-fv
make zkbuild-native-qemu-test
make zkbuild-byte-native-qemu-test
```

`make zkbuild` prepares the host tool and runs the bounded profile checks.
`zkbuild-fv` builds the Lean models. The native QEMU targets exercise
verified execution of the fixed-slot and byte-stream native artifacts.
For dependencies, setup, and finer gates, see the
[Makefile](../Makefile) and [Lean project](../formal/zkbuild/).

The setup pins Constantine and prepares its local RV32 portability overlay
under `build/zkbuild-deps/`. Keep keys, proofs, and generated code under
`build/`. Verification requires the claim's matching key and exact artifact.
Use the supplied regression targets to exercise wrong-key and altered-input
cases.

## General validation research

The general validation witness extracts events from the decoded WASM,
including operand and control frame changes. The replay checker and
R1CS components bind increasingly larger pieces of that event stream.
Source-bound control signature lists and individual stack, lookup,
memory, and byte-decoder relations have separate evidence. General
instruction-body composition and full module admission remain open.

Use the [formal models](../formal/zkbuild/) and
[prior proof reference](https://github.com/gabearro/bl808-hal-nim/blob/eb932dddbb56ac5131b3d398e5463f18008fc639/docs/zkbuild.md)
for exact theorem boundaries, counterexamples, and earlier measurements.
