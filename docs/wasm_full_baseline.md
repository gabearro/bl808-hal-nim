# Full interpreter baseline for M0, D0, and LP

The common guest contract is `tools/wasm_full_baseline.wat`, embedded as
immutable bytes in `src/bl808/wasm_full_baseline.nim`. Every build uses
`cps/wasm/binary.nim`, `validate.nim`, and the same `runtime.nim` interpreter.
LP lowers floating point through the vendored RV32E compiler-rt and musl math
subset. No T-Head extension is enabled. The test exercises i32 arithmetic,
f64 arithmetic, and `call_indirect`; the legacy compact VM rejects this corpus.

Run the non-hardware gate from the repository root:

```sh
python3 tools/run_wasm_full_baseline.py
python3 tools/run_wasm_full_baseline.py --d0-xip
python3 tools/run_wasm_full_baseline.py --bench
python3 tools/run_wasm_full_baseline.py --manager-qemu
python3 tools/run_wasm_full_baseline.py --scheduler-qemu --scheduler-firmware
.venv/bin/python -m pytest -q tools/test_wasm_lp_no_softfloat.py
```

The first command compares the WAT output with embedded bytes, runs a host
test, cross-links three native firmware images, checks each image contains the
full interpreter and no compact interpreter, and executes the same guest on
QEMU `rv32`, `rv64`, and `rv32e` CPUs with target-matched ISA and ABI. Outputs
are isolated under `build/wasm-full-baseline/`; the script does not open the
hardware bench. It requires Nim 2.2.6, `wat2wasm`, `riscv64-unknown-elf-gcc`,
`riscv64-unknown-elf-size`, and both QEMU system binaries.
It also runs `tools/wasm_lp_arena_growth.wat` against the full interpreter
compiled with the LP arena settings on the host. That case exceeds each
initial LP stack arena and checks that recursive calls, labels, locals, and
operand values grow correctly.

Measured on 2026-11-22 with the current checkout:

| Build | Native text | .data | .bss | Heap region | Native stack | QEMU heap peak | QEMU stack used | Instance allocation |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| M0, RV32IMAF(C) | 160,960 | 112 | 2,340 | 54,380 | 8,192 | 11,400 | 2,512 | 2,464 |
| D0, RV64IMAFDC | 148,320 | 224 | 4,600 | 362,888 | 8,192 | 47,168 | 4,464 | 3,776 |
| LP, RV32EMC | 160,552 | 112 | 2,212 | 9,964 | 4,096 | 5,920 | 2,352 | 2,464 |

The instance figure is the increase in used heap from VM initialization to
instantiation of this 118-byte module. The QEMU LP linker enforces the same
16 KiB writable budget and 4 KiB stack as the firmware; its heap varies with
the test image's `.data` and `.bss`. The LP stack canary showed that 2 KiB was
insufficient; this image reserves 4 KiB within the existing 16 KiB WRAM.
Heap peaks are specific to this small corpus, not module admission limits.
The LP initial value, call, label, and locals arenas use 32, 4, 8, and 16
entries respectively, and the indirect-call cache uses four two-way slots.
This reduced the same corpus's peak heap use from 6,760 to 5,920 bytes while
retaining its guest features. The optional benchmark measures 128 warmed invocations of each
export with QEMU `mcycle`; these counts are emulator observations, not Ox64
cycles or real-time bounds.

| QEMU CPU | i32 add cycles/invoke | f64 cycles/invoke | indirect call cycles/invoke |
| --- | ---: | ---: | ---: |
| M0 RV32 | 4,953 | 4,015 | 5,320 |
| D0 RV64 | 5,546 | 4,570 | 5,875 |
| LP RV32E | 5,023 | 4,132 | 5,335 |

The shared branch helper now moves multi-value results in place. The LP
compiler's stack report for that helper fell from 1,068 to 28 bytes. A host
regression test branches with 129 ordered i32 results, beyond the previous
fixed 128-value buffer; the original 118-byte QEMU corpus does not exercise
that branch path, so its total stack high-water measurement is unchanged.
Run the separate test with `python3 tools/run_wasm_branch_stack.py`.

M0 and LP native text and embedded guest bytes link into flash XIP windows.
D0 currently links text and guest bytes into DRAM. Each image has its own copy
of the immutable guest bytes; sharing one flash address across cores and
concurrent XIP have not been validated. This gate does not use LP PSRAM, an SD
card, the D0 MMU, JIT, or live flash writes.

The optional `-d:bl808D0Xip` D0 linker script places native text and read-only
data at `0xD8100000` (the D0 MM flash-remap alias of the flash slot at
`0x100000`), with `.data`, `.bss`, heap, and stack in D0 DRAM. The optional
build uses the same remap alias for flash-backed WASM repository reads, while
the DRAM build retains its `0x58000000` read alias. The optional
build check above verifies the ELF entry, copy-data load address, first
instruction, and image length without touching the board. The M0
`releaseD0Xip()` helper leaves D0 in reset if the entry signature or expected
zero SF image remap is absent; the existing `releaseD0()` DRAM path remains
available. The address is drawn from Bouffalo's
[BL808 register map](https://github.com/bouffalolab/bl808_linux/blob/main/bl_mcu_sdk_bl808/drivers/bl808_driver/regs/bl808.h)
and the vendor [flash slot convention](https://github.com/bouffalolab/bflb_linux_fw).
This does not establish that the Ox64 can boot the XIP image or run it
concurrently with M0/LP XIP. It must be exercised through a scoped harness
test after the shared bench is free.

### Typed function-reference instructions

```sh
python3 tools/run_wasm_full_baseline.py --function-references --d0-xip
```

The opt-in `-d:wasmFunctionReferences` profile adds `call_ref`,
`return_call_ref`, `ref.as_non_null`, concrete nullable locals, and nullable
and non-nullable function reference parameters and results to the shared
interpreter. The validator preserves those types through calls, indexed
blocks, branches, and returns. It treats `nofunc` as the null-only subtype.
Recursive function groups can refer to their own members and link across
modules by structural identity. Declared subtypes check parameter
contravariance and result covariance. Tables support nullable and
non-nullable function references. An explicit table initializer is evaluated
once before active element segments are applied. It can name a function or
read an immutable imported global. Globals also support typed function
references. Read-only global imports allow a subtype, and mutable global
imports require the same type. Inline typed block and select immediates remain open.
[Core WebAssembly instruction validation](https://webassembly.github.io/spec/core/valid/instructions.html)
[Core WebAssembly recursive types](https://webassembly.github.io/spec/core/valid/types.html#recursive-types)
[Core WebAssembly table binary format](https://webassembly.github.io/spec/core/binary/modules.html#table-section)
[Core WebAssembly global type matching](https://webassembly.github.io/spec/core/valid/matching.html#global-types)

The gate checks the WAST corpus with `wasm-tools` and runs valid, trapping,
invalid, malformed, and incompatible-link inputs on the host. The host
rejects forged, null, and wrong-type arguments to a non-nullable function
reference parameter. It freezes a tail-replaced guest frame and restores it
against the original entry export. Buffered and streamed captures reject
invalid table and global references. The receiver revalidates them before
restoring them. A smaller module from the same corpus exercises explicit
table initialization, typed parameters, results, and locals, `call_ref`,
and 1,024 recursive `return_call_ref` steps across execution slices through
the full manager on RV32, RV64, and RV32E QEMU. Native builds include the
same probe. The D0 DRAM build is available alongside the optional XIP build.

| Core | Native `.data` | Native `.bss` | QEMU heap peak | QEMU stack used |
| --- | ---: | ---: | ---: | ---: |
| M0 RV32 | 196 B | 2,340 B | 15,168 B | 4,160 B |
| D0 RV64, DRAM | 392 B | 4,600 B | 52,768 B | 7,184 B |
| LP RV32E | 196 B | 2,212 B | 9,680 B | 3,952 B |

The LP probe keeps the 16 KiB writable layout and 4 KiB stack reservation.
The combined host corpus exceeded the LP probe's heap during decode, so
the LP-sized module carries the typed local and call cases and the host
executes the separate null-trap module and the invalid binary cases.

The native probe writes `0x57465200` on success to the baseline status
address for its core, with capabilities at offset 4 and peak heap bytes
at offset 8. The status and actual flash execution require an Ox64 run.

### Shared core function types, tables, and globals

```sh
python3 tools/run_wasm_full_baseline.py --shared-core-types --function-references --d0-xip
```

`-d:wasmSharedCoreTypes` adds shared core function types, shared
`func`/`nofunc` references, shared function reference tables, and shared
scalar and function-reference globals to the opt-in typed interpreter. It uses the
shared-everything threads draft at revision `de560922268ca89fd3303776c5c1b8f123da2aec`.
Sharedness participates in recursive type equality, subtyping, store
imports, and embedding arguments. Shared bodies require shared reference
locals and shared targets for direct and reference calls. The validator
requires shared tables and reference globals to use shared reference types.
Shared functions can access shared tables, global cells, and element
segments. Table and global imports preserve store identity and must agree
on sharedness.
[Pinned shared-everything threads draft](https://github.com/WebAssembly/shared-everything-threads/blob/de560922268ca89fd3303776c5c1b8f123da2aec/proposals/shared-everything-threads/Overview.md#shared-annotations)

The host gate runs the shared function, table, and global corpora against
`wasm-tools` and the interpreter. It also checks the draft's isolation
rules and a passive segment with its sharedness bit. The native and QEMU
probes run shared locals, reference calls, sliced tail recursion, table
initialization and updates, and shared global reads and writes. A separate
small guest runs an i64 atomic add with one instruction per execution
slice on all three CPU profiles. The native probe reports
`0x57534300` through the baseline status address. M0, D0 DRAM, D0 XIP,
and LP builds link. Physical execution remains pending.

| Profile | Native `.data` | Native `.bss` | QEMU heap peak | QEMU stack used |
| --- | ---: | ---: | ---: | ---: |
| M0 RV32 | 196 B | 2,340 B | 15,248 B | 4,160 B |
| D0 RV64, DRAM | 392 B | 4,600 B | 53,000 B | 7,024 B |
| LP RV32E | 196 B | 2,212 B | 9,760 B | 3,960 B |

The LP probe retains the 16 KiB writable layout and 4 KiB stack reservation.
The QEMU stack high-water leaves 136 bytes in that reservation.

The interpreter executes shared functions, tables, and globals in one store.
The opt-in profile supports integer global atomic get, set, add, subtract,
and, or, xor, exchange, and compare-exchange. Each operation runs within
one dispatch in the store's serialized executor. The JIT compilers leave
these instructions to the interpreter.

The host corpus checks i32 wraparound, i64 operations, success and failure
of compare-exchange, and rejection of invalid types, immutable writes,
and inaccessible globals. The pinned encoding uses `0x11` for
acquire-release read-modify-write. `wasm-tools 1.263.0` reads a single ordering
nibble for these operations, so the gate checks sequentially consistent
read-modify-write with the tool and generates the draft-format
acquire-release guest separately.
[Pinned atomic binary encoding](https://github.com/WebAssembly/shared-everything-threads/blob/de560922268ca89fd3303776c5c1b8f123da2aec/proposals/shared-everything-threads/Overview.md#memory-orderings)
[wasmparser 1.263.0 atomic reader](https://github.com/bytecodealliance/wasm-tools/blob/v1.263.0/crates/wasmparser/src/binary_reader.rs)

Portable snapshots reject shared tables, globals, memories, and segments
until there is a transferable backing. Shared v128 global instructions
require SIMD support. Cross-core storage and ordering, GC-reference
atomics, and preemptive execution remain open. The
pinned draft describes thread-local globals and leaves their binary
encoding unspecified.
[Pinned draft binary format and thread-local globals](https://github.com/WebAssembly/shared-everything-threads/blob/de560922268ca89fd3303776c5c1b8f123da2aec/proposals/shared-everything-threads/Overview.md#thread-local-storage-tls)

### Shared linear memory and data segments

The same `--shared-core-types` command builds the shared-memory probe.
The validator requires an explicit maximum for shared memory and checks
both memory indices of `memory.copy`. A shared function can use shared
memory and shared data segments. The pinned draft encodes data segment
sharedness in bit 3 of the mode field. The test runner applies that bit
to toolchain-generated active and passive data segments.
[Threads memory type and encoding](https://github.com/WebAssembly/threads/blob/main/proposals/threads/Overview.md#shared-linear-memory)
[Pinned shared data encoding](https://github.com/WebAssembly/shared-everything-threads/blob/de560922268ca89fd3303776c5c1b8f123da2aec/proposals/shared-everything-threads/Overview.md#types-1)

Core modules within one store can import the same shared memory. The
import checks sharedness and the memory's current size, including growth
by the provider. A raw host memory value cannot represent this shared
identity in the current embedding API. The host and native probe use the
CRC-checked image loader and existing chunked memory backend with two
512-byte resident chunks. They cover growth, a store across a 64 KiB
guest page boundary, overlapping copy, fill, and active and passive data
initialization. The native status code is `0x57534D00`.

| Shared-memory profile | Native `.data` | Native `.bss` | QEMU heap peak | QEMU stack used |
| --- | ---: | ---: | ---: | ---: |
| M0 RV32 | 196 B | 2,340 B | 11,696 B | 4,240 B |
| D0 RV64, DRAM | 392 B | 4,600 B | 47,136 B | 7,136 B |
| LP RV32E | 196 B | 2,212 B | 6,216 B | 4,008 B |

The LP probe uses the 16 KiB writable layout and leaves 88 bytes in its
4,096-byte stack reservation at the observed QEMU high-water mark. The
fixture uses resident SRAM chunks on each CPU profile.
Physical cross-core access, backing I/O, and memory ordering require
their own verification.

The shared interpreter implements sequentially consistent loads, stores,
and read-modify-write operations for full-width and subword accesses,
along with `atomic.fence`. It validates natural alignment, enforces bounds
and effective address alignment at runtime, and zero-extends subword
results. These instructions run in the
serialized store executor for both shared and ordinary memory. With
multi-memory enabled, each instruction uses its specified memory index.
The JIT leaves these operations to the interpreter. Ordering across
physical cores remains open.
[WebAssembly threads atomic memory accesses](https://github.com/WebAssembly/threads/blob/main/proposals/threads/Overview.md#atomic-memory-accesses)

The same gate checks the atomic corpus with `wasm-tools` and the host VM.
The one-frame host case forces an eviction at the write and a page-in at
the read of separate read-modify-write operations. It injects a failed
backing read, then verifies exact restored values and fuel accounting.
The native probe uses two resident chunks on opposite sides of a 64 KiB
guest page boundary. Every naturally aligned access fits one chunk.

### Cooperative atomic wait and notify

`python3 tools/run_wasm_full_baseline.py --atomic-wait --d0-xip` checks
`memory.atomic.wait32`, `memory.atomic.wait64` and `memory.atomic.notify`
with `wasm-tools` and the opt-in interpreter. A value mismatch returns 1,
a timeout returns 2, and a notification returns 0 to an enrolled waiter.
The serialized store keeps a FIFO keyed by memory identity and byte
offset. A notification can wake either wait width at that address. A cold
chunk is read before enrollment, so a notification counts only actual
waiters. The interpreter charges a parked wait once. By default a store
admits four parked waits on LP and 16 on larger profiles.
[WebAssembly wait and notify semantics](https://github.com/WebAssembly/threads/blob/main/proposals/threads/Overview.md#wait-and-notify-operators)
[WebAssembly wait queue ordering](https://webassembly.github.io/threads/core/exec/relaxed.html)

An actual wait parks a sliced guest arena. The BL808 tickless driver
supplies the store clock and rearms on a finite timeout. An embedding
with its own executor uses `setWasmAtomicClock` or
`setComponentAtomicClock` for finite waits. The host test runs the
kernel's timed-hook adapter with a controlled clock and verifies that a
5,000 ns wait wakes after five ticks at 1 MHz. Hard slots reject these
instructions. Parked waits stay with the owning store and cannot be
captured for migration. `supportsAtomicWait` reports compiled support,
also recorded in bit 7 of the smoke capability word. Timer delivery on
the board and memory shared by different physical cores require separate
validation.

The native probe passes when one arena parks in `wait64` and a second
arena wakes it. It loads both exports through the CRC-checked full VM
image path and uses a 512-byte chunked backend. LP's atomic-wait probe
reserves 4,608 stack bytes within its 16 KiB writable layout. Its native
status code is `0x57415700`.

| Atomic-wait profile | Native `.data` | Native `.bss` | QEMU heap peak | QEMU stack used |
| --- | ---: | ---: | ---: | ---: |
| M0 RV32 | 224 B | 2,340 B | 11,136 B | 4,272 B |
| D0 RV64, DRAM | 448 B | 4,600 B | 46,232 B | 7,248 B |
| LP RV32E | 224 B | 2,212 B | 5,544 B | 4,104 B |

The opt-in `-d:wasmChunkedMemory` runtime path accepts a per-memory factory
for 4 KiB resident chunks while preserving WebAssembly's 64 KiB guest pages.
`src/cps/wasm/linear_memory.nim` bounds guest offsets, enforces page and
committed-chunk quotas, supports pinning, and writes dirty chunks to a bounded
backing store before eviction. `src/bl808/wasm_sd_backing.nim` adapts the
M0-owned preallocated SD swap file. Host tests cover grow, page-boundary
loads/stores, overlapping bulk copy, exact dirty-page round trips, and I/O
failures. The backend now reports a pending chunk fault and has cursor-based
read, write, and overlapping-copy operations. A one-frame host test suspends
each transfer on `lmWouldBlock`, services its fault outside the transfer, and
resumes without replaying earlier bytes. The opt-in full interpreter and
full-task scheduler now suspend on chunk misses. Scalar loads/stores and bulk
init, copy, and fill retain transfer progress; the scheduler services the
fault outside the guest slice. A failed backing service traps that task. The
default full interpreter still uses its flat memory path, and normal unsliced
execution still performs backing I/O synchronously. A hard slot may use
chunked memory only with a pinned resident working set; no deadline guarantee
has been measured.

### SRAM and PSRAM frame reservations

M0 and D0 can opt into `-d:wasmTieredFrames` and pass
`wasmPsramMemoryFactory` to the existing full scheduler or program manager.
The board supplies a dedicated local SRAM span and a disjoint offset in the
BL808 PSRAM window. The factory checks the ranges, takes one lease per live
memory, and releases it when the VM drops that memory. Scheduler telemetry
reports SRAM and PSRAM resident chunks for this factory.

Newly committed chunks use available SRAM frames first and then PSRAM. Pinning
a PSRAM chunk promotes it to SRAM and preserves the displaced unpinned chunk's
data.
Hard slots continue to require a fully pinned committed working set.
With no SD backing, the commit quota is capped at the number of resident
frames. With backing, the owner can assign a bounded swap slot slice to
each reservation. The slot slice uses the existing clock and page callbacks.
The board must keep the reservations disjoint across cores and retain any
backing until its transfers have stopped. No PSRAM frames are enabled on LP.

`python3 tools/run_wasm_full_baseline.py --psram-frames-qemu --lp-pager-client-qemu`
runs the full interpreter baseline on all three cores, the SRAM/PSRAM
fixture on M0 and D0, and the existing LP pager with an in-process server.
The M0/D0 guest runs through the full scheduler and makes a store and load
across a 64 KiB page boundary using one frame in each tier. Ordinary emulator
RAM stands in for both physical regions. The host test also checks promotion,
pin exhaustion, lease reuse, dirty eviction, exact swap-in, failed I/O and
full backing with pure memory callbacks.

| QEMU SRAM/PSRAM fixture | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 9,736 | 3,568 |
| D0 | 44,632 | 6,032 |

```sh
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src --mm:arc \
  -d:bl808WasmFullScheduler -d:wasmChunkedMemory -d:wasmTieredFrames \
  -d:WasmMemoryChunkBytesConfig=512 tools/test_wasm_psram_frames.nim
```

The separate `examples/wasm_psram_frames_build_test.nim` image cross-links
for M0 and D0. It requires an explicit `WasmPsramProbeOffset`, an initialized
PSRAM controller, and debugger arming after the region has been reserved.
The probe's PSRAM accesses stay within the selected scratch frame. The
physical PSRAM path still requires an Ox64 run. D0 still needs integration
with the M0-owned SD service and an end-to-end swap-in test. The PSRAM
window uses the mapping in the
[BL808 reference manual, version 1.3](https://raw.githubusercontent.com/bouffalolab/bl_docs/main/BL808_RM/en/BL808_RM_en_1.3.pdf).

For build-only validation, use the sample offset 65011712 on M0 and
65012224 on D0. These values are build inputs for the isolated probe.

```sh
nim c -d:bl808m0 -d:bl808kernel -d:bl808WasmFull -d:bl808WasmFullScheduler \
  -d:WasmSchedulerMaxTasks=1 -d:wasmChunkedMemory -d:wasmTieredFrames \
  -d:WasmMemoryChunkBytesConfig=512 -d:WasmPsramProbeOffset=65011712 \
  --nimcache:build/wasm-psram-frames/m0-cache --out:build/wasm-psram-frames/m0.elf \
  examples/wasm_psram_frames_build_test.nim
```

Use `-d:bl808d0`, the D0 offset, and a separate cache and output path for D0.

The opt-in `wasm_page_client.nim` shares one bounded XRAM IPC client between
D0 and LP. It fragments each 512-4096-byte chunk into at most
18 existing bridge RPC payloads, performs no IPC on a resident guest load,
and checks a whole-chunk CRC before the fault is cleared. M0's
`wasm_page_server.nim` owns a 4 KiB staging buffer and adapts the dedicated
preallocated `sd_swap_file.nim`; a missing card leaves the service unavailable.
The wire handler rejects stale sessions, bad slots, out-of-order writes,
checksum errors, and failed backing I/O. `local_atomic.c` supplies the two
CPS future atomic operations needed by this RV32E toolchain using LP-local
interrupt exclusion. It is only valid for LP-private future state; XRAM still
uses the IPC bridge's explicit cache and ownership handoff.

The host wire and client tests pass. The `--lp-pager-client-qemu` gate runs a
full VM task through the LP client and an in-process server on QEMU RV32E,
including eviction and exact swap-in. The current QEMU build used 3,528
bytes of heap and 3,284 bytes of native stack. The separate LP firmware link for
`examples/lp_wasm_page_client_build_test.nim` has 392 bytes `.data`, 5,704
bytes `.bss`, a 4,656-byte heap, and a 5,632-byte stack within LP's 16 KiB
writable region. That link is only a capacity check: its heap margin relative
to the QEMU fixture is small, the actual kernel IPC path and SD service have
not run together on the Ox64, and QEMU does not model the board's XRAM/SD
timing. M0's `examples/m0_wasm_page_server_build_test.nim` links with 60 bytes
`.data`, 10,284 bytes `.bss`, a 46,484-byte heap, and an 8,192-byte stack.
It mounts and opens only `bl808swap_safe/lp_wasm.swap` after an explicit
trigger, then registers the page handler. Bench validation and more LP heap
headroom are required before enabling this path by default.

The M0 SD backing adapter now requires caller-owned 4 KiB staging when the
VM is built with 512, 1,024, or 2,048-byte chunks. Each such chunk occupies
one preallocated 4 KiB swap-file slot; writes zero the unused tail and reads
copy only the configured chunk length. This prevents a 4 KiB FatFs read from
overwriting a smaller VM frame. The 512-byte M0 page-server image links with
60 bytes `.data`, 14,408 bytes `.bss`, 42,360 bytes of heap, and an
8,192-byte stack. The adapter and SD service still require a device round
trip with the actual card; the link only checks capacity.

The chunk backend also accepts an optional local monotonic tick callback.
It records total and maximum successful page-in/page-out callback time and
the maximum time from a suspended chunk fault to its successful service.
The M0 SD adapter and peer page clients supply their core-local tick source in
kernel builds, and `getWasmTaskMemoryTelemetry` aggregates those counters
for a live full task. These are elapsed local ticks; a QEMU or host tick
assertion does not bound SD-card latency or cross-core clock skew on Ox64.

Reproduce this stage without touching hardware:

```sh
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on tools/test_wasm_page_wire.nim
nim c -r -d:bl808lp -d:wasmPageWireHostTest \
  --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on tools/test_wasm_lp_page_client.nim
python3 tools/run_wasm_full_baseline.py --lp-pager-client-qemu
nim c -d:bl808lp -d:bl808kernel -d:bl808WasmFull \
  -d:bl808WasmFullScheduler -d:wasmChunkedMemory \
  -d:WasmSchedulerMaxTasks=1 -d:WasmMemoryChunkBytesConfig=512 \
  -d:WasmLpNativeStackBytes=5632 \
  -d:MaxRpcHandlers=1 -d:MaxPendingCalls=1 -d:MaxIpcCompletions=1 \
  --passL:-Wl,--defsym=__bl808_lp_stack_bytes=5632 \
  --nimcache:build/wasm-lp-page-firmware/cache \
  --out:build/wasm-lp-page-firmware/lp.elf \
  examples/lp_wasm_page_client_build_test.nim
nim c -d:bl808m0 -d:bl808kernel -d:MaxRpcHandlers=1 \
  --nimcache:build/wasm-m0-page-firmware/cache \
  --out:build/wasm-m0-page-firmware/m0.elf \
  examples/m0_wasm_page_server_build_test.nim
```

### D0 remote swap with tiered resident frames

The opt-in dual-peer M0 probe opens `bl808swap_safe/full_wasm.swap` with
eight preallocated slots. LP owns the first four and D0 the last four. The
server selects the peer from the IPC request slot and keeps separate sessions
and write staging. M0 and both clients must use the same chunk size. Each
peer has one outstanding transfer, and these probes run one paging VM per
peer. A canceled transfer detaches its frame immediately. Keep its client
buffer alive until the IPC future completes or times out.

`--d0-pager-client-qemu` runs a guest that dirties three 512-byte chunks
with one SRAM frame and one emulated PSRAM frame. The full interpreter
suspended, wrote three pages to the in-process backing, read two back,
and returned the exact cross-page value `0x12345678`. D0 QEMU used 43,576
heap bytes and 6,080 stack bytes. The D0 firmware link has 808 bytes `.data`,
11,360 bytes `.bss`, a 231,896-byte heap and an 8,192-byte stack. The M0
dual-peer image links with 60 bytes `.data`, 14,408 bytes `.bss`, a 42,360-byte
heap and an 8,192-byte stack. It allocates D0's extra staging buffer at setup.
The physical D0 PSRAM window, XRAM transport, SD round trip and latency need
an Ox64 run. The QEMU backing lives in emulator RAM.

```sh
python3 tools/run_wasm_full_baseline.py --lp-pager-client-qemu --d0-pager-client-qemu
nim c -d:bl808m0 -d:bl808kernel -d:WasmMemoryChunkBytesConfig=512 \
  -d:MaxRpcHandlers=1 -d:wasmD0PageServerProbe \
  --nimcache:build/wasm-d0-page/m0-cache --out:build/wasm-d0-page/m0.elf \
  examples/m0_wasm_page_server_build_test.nim
nim c -d:bl808d0 -d:bl808kernel -d:bl808WasmFullScheduler -d:wasmChunkedMemory \
  -d:wasmTieredFrames -d:WasmSchedulerMaxTasks=1 -d:WasmMemoryChunkBytesConfig=512 \
  -d:WasmPsramProbeOffset=65012224 \
  --nimcache:build/wasm-d0-page/d0-cache --out:build/wasm-d0-page/d0.elf \
  examples/d0_wasm_page_client_build_test.nim
```

The offset in the build command is for compile validation. On the device,
the harness must establish ownership of the aligned PSRAM range and initialize
it before arming the D0 worker. Confirm M0's ready value `0x57504D00` at
`0x40002E10` first. D0 waits for `0x575044A5` at `0x40003F70` and reports
status, page-ins, page-outs and heap high water at `0x40003F60` through
`0x40003F6C`. Pass is `0x57504400` with nonzero page-in and page-out counts.

The shared full interpreter also has `executeSlice`, which saves guest PC and
stack arenas at instruction boundaries and resumes on the same core. The
LP-sized host regression exercises repeated slices, recursive calls, deep
labels, value-stack growth, trap cleanup, and abort. Instruction budgeting
does not bound host imports or synchronous backing I/O, and a live native
interpreter frame is never migrated between cores.

`src/bl808/wasm_full_manager.nim` opens the existing CRC-checked slot image
through `wasm_store.nim`, fully decodes and validates it, then retains the
immutable source bytes in its XIP view while dropping duplicate compact-parser
metadata. It rejects flat linear memories on M0/LP, where one 64 KiB guest
page exceeds the local heap; an opt-in chunk factory is required for those
modules. `--manager-qemu` executes a wrapped baseline guest through this
adapter on all three target ISA/ABI emulators. QEMU peak heap/native stack
bytes were M0 12,656/3,088, D0 49,048/5,408, and LP 7,176/2,948. These are
small-module observations, not admission bounds for arbitrary modules or
evidence of physical flash XIP on the Ox64.

With `-d:bl808WasmFullScheduler`, the existing `wasm_scheduler.nim` task table
can run an i32-export full-VM job through the same slot loader. It retains its
bounded task IDs, fuel quota, yield, trap, reap, and kill lifecycle. Full jobs
charge actual decoded interpreter instructions per slice; the compact path
keeps its original accounting. The opt-in path is deliberately limited to one
LP task (`-d:WasmSchedulerMaxTasks=1`) until memory admission covers larger
programs. `tools/test_wasm_full_scheduler.nim` checks completion, quota, and
teardown on the host. The QEMU scheduler case passes on M0, D0, and LP; the
LP image uses 200 bytes `.data`, 2,948 bytes `.bss`, a 9,104-byte QEMU heap,
and a 4,096-byte stack. Its observed heap peak was 7,176 bytes and stack use
3,052 bytes. The QEMU linker now derives the heap from the remaining 16 KiB
writable budget and asserts that the entire writable region fits.

`examples/wasm_full_scheduler_test.nim` cross-links on all three cores with
`--scheduler-firmware`, but has not run on hardware. The LP firmware image
uses 242,064 bytes `.text`, 200 `.data`, 3,156 `.bss`, 8,932 heap, and 4,096
stack; its heap is 172 bytes smaller than the QEMU scheduler image because
the firmware startup and diagnostics differ. M0 and D0 firmware also link.
The execution budget is an instruction count, not a measured time bound;
host imports and page I/O remain synchronous in unsliced execution. The
opt-in scheduler can suspend page faults. Its bounded migration path for
standalone guests is covered in [WASM work stealing](wasm_work_stealing.md).

The opt-in `-d:bl808WasmRtPolicy` scheduler adds a fixed-size, core-local
cyclic reservation table on top of the same task IDs. It checks hard-slot
overlap, affinity, declared resident working set and bounded imports, then
dispatches a reserved job within its slot. Soft jobs use earliest deadline
first; best-effort jobs run in slack when their declared worst-case slice
fits before the next hard slot. It samples a caller-supplied monotonic clock
around each interpreter slice and records start jitter, deadline misses,
slice/budget overruns and hard memory faults. Hard violations stop the task;
soft overrun policy can continue, demote, or stop it. The host checks are:

Hard `releaseTick` is the absolute earliest activation. A hard
`deadlineTick` is an offset from each frame start; zero uses the reserved
slot end. Hard start, deadline and budget accounting reset for each frame,
while soft deadlines and budgets stay absolute and cumulative. The policy
test exercises three successive hard frames and a within-frame budget
overrun. The dispatcher counts completed hard reservations without a
guest start and expired soft deadlines, including when no task is
runnable. Soft completion at the deadline is on time. A job that remains
blocked at the following tick records one miss.
An LP build of the one-task full scheduler with the real-time policy linked
uses 200 bytes `.data`, 4,160 bytes `.bss`, a 7,928-byte heap and a 4,096-byte
native stack. It links within the 16 KiB region; the separate QEMU scheduler
fixture used 7,176 heap bytes without the real-time policy, so the measured
margin is narrow and the combined firmware still needs a device run.

```sh
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on \
  --nimcache:build/wasm-rt/policy-cache \
  --out:build/wasm-rt/policy-test tools/test_wasm_rt_policy.nim
nim c -r -d:bl808WasmFullScheduler -d:bl808WasmRtPolicy \
  -d:wasmRtKernelTest \
  --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on \
  --nimcache:build/wasm-rt/scheduler-cache \
  --out:build/wasm-rt/scheduler-test tools/test_wasm_rt_scheduler.nim
```

`src/bl808/wasm_rt_kernel.nim` attaches the policy to one rearmable timed
poll hook in the existing kernel. The hook wakes at a known release,
reservation boundary, or deadline check and disarms when there are no
future events. Task admission, unblocking, activation, and removal can
change its deadline. It executes one slice per poll so other kernel
callbacks retain their normal turn. Attach after `schedulerInit()` and
`initWasmRtScheduler()`. The driver owns guest execution while attached.
Its default fallback accepts explicitly admitted tasks only. A nonzero
fallback slice bound allows unregistered best-effort jobs to use slack.

RT builds keep the last ready check and WFI inside the same interrupt
critical section. Locally enabled pending interrupts can wake WFI with
global MIE clear, so the timer ISR can clear the compare after the core
leaves WFI. The LP tick reader also checks for a rollover between its
32-bit reads. [RISC-V WFI requirements](https://docs.riscv.org/reference/isa/priv/machine.html)

Real-time admission still requires a measured maximum slice time, a
resident working set and bounded imports. Remote soft jobs can use the
clock correlation and admission path in [WASM work stealing](wasm_work_stealing.md).
Physical clock skew, interrupt, shared-bus, Wi-Fi and DMA interference
still need Ox64 measurements.

The full interpreter now accepts an optional core-local deadline clock for
`executeSlice`. It yields before the next guest instruction once that clock
reaches the dispatch cutoff. The RT scheduler supplies the end of a hard
slot or the start of the next hard slot for soft/best-effort full tasks. It
rejects compact hard tasks, host imports, memory/table growth and bulk
operations, and flat or unpinned chunked memory. A chunked hard task must
have every committed chunk resident and pinned with its commit quota already
full. This excludes new frame allocation during the slot; an unexpected
write to an uncommitted chunk traps instead of paging. The checks do not
establish a worst-case duration for one instruction, interrupt latency, or
native allocations elsewhere in the interpreter. The scheduler still checks
actual elapsed time after each slice and stops a hard task on an overrun.

`tools/wasm_rt_resident.wat` is a concrete one-chunk hard-slot workload. It
writes and reads a fixed address in the pinned 512-byte chunk, adds three,
and returns `305419899`. It has no imports, bulk operations, peer calls,
SD access, or flash writes. The test pins memory and starts the common full
scheduler task after image decode, validation and instantiation. A synthetic-clock
host test checks admission and zero faults; separate QEMU images execute the
same guest on M0 RV32, D0 RV64 and LP RV32E. The QEMU adapter registers the
WASM driver's timed hook, programs the emulated CLINT compare at the
planned release, observes a timer wake from WFI, and calls the hook. It
checks that the task ran once and disarmed the deadline after completion.
The QEMU `virt` timer in this run ticks at 10 MHz. The jitter and slice
times below are emulator observations.

| QEMU core | Slice ticks | Start jitter ticks | Peak heap | Native stack used |
| --- | ---: | ---: | ---: | ---: |
| M0 | 16,480 | 108,640 | 9,136 | 4,128 |
| D0 | 15,240 | 105,590 | 43,768 | 5,840 |
| LP | 17,750 | 111,770 | 3,648 | 4,084 |

The LP QEMU image reserves a 5,632-byte stack. The matching build-only
LP firmware reserves 240 bytes of `.data`, 6,548 bytes of `.bss`, 3,964
bytes of heap and 5,632 bytes of stack within 16 KiB. The LP QEMU heap
peak is 316 bytes below the native heap reservation. The firmware entry
`examples/wasm_rt_resident_build_test.nim` enters the actual kernel with
a future reservation and reports after the slot. Pass status is
`0x57525400`, peak heap is at status+4, maximum slice ticks at status+8,
and maximum start jitter at status+12. Ox64 timer wiring, interrupt
delivery, and start jitter still need hardware validation.

Reproduce without accessing the bench:

```sh
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on tools/test_wasm_deadline_preemption.nim
wat2wasm tools/wasm_rt_resident.wat -o build/wasm-rt/resident.wasm
wat2wasm tools/wasm_rt_unbounded.wat -o build/wasm-rt/unbounded.wasm
nim c -r -d:bl808WasmFullScheduler -d:bl808WasmRtPolicy \
  -d:wasmChunkedMemory -d:WasmMemoryChunkBytesConfig=512 \
  --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on tools/test_wasm_rt_resident.nim \
  build/wasm-rt/resident.wasm build/wasm-rt/unbounded.wasm
python3 tools/run_wasm_full_baseline.py --rt-resident-qemu
for core in m0 d0; do
  nim c -d:bl808$core -d:bl808kernel -d:bl808WasmFull \
    -d:bl808WasmFullScheduler -d:bl808WasmRtPolicy \
    -d:wasmChunkedMemory -d:WasmMemoryChunkBytesConfig=512 \
    -d:WasmSchedulerMaxTasks=1 \
    --nimcache:build/wasm-rt/resident-firmware-$core-cache \
    --out:build/wasm-rt/resident-firmware-$core.elf \
    examples/wasm_rt_resident_build_test.nim
done
nim c -d:bl808lp -d:bl808kernel -d:bl808WasmFull \
  -d:bl808WasmFullScheduler -d:bl808WasmRtPolicy \
  -d:wasmChunkedMemory -d:WasmMemoryChunkBytesConfig=512 \
  -d:WasmSchedulerMaxTasks=1 -d:WasmLpNativeStackBytes=5632 \
  --passL:-Wl,--defsym=__bl808_lp_stack_bytes=5632 \
  --nimcache:build/wasm-rt/resident-firmware-lp-cache \
  --out:build/wasm-rt/resident-firmware-lp.elf \
  examples/wasm_rt_resident_build_test.nim
```

Run the memory host checks without hardware:

```sh
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on \
  --nimcache:build/wasm-linear-memory/host-cache \
  --out:build/wasm-linear-memory/host-test tools/test_wasm_linear_memory.nim
wat2wasm tools/wasm_chunked_memory.wat -o build/wasm-linear-memory/guest.wasm
nim c -r -d:wasmChunkedMemory --skipUserCfg --skipParentCfg --skipProjCfg \
  --path:src --checks:on --assertions:on \
  --nimcache:build/wasm-linear-memory/vm-cache \
  --out:build/wasm-linear-memory/vm-test tools/test_wasm_chunked_vm.nim \
  build/wasm-linear-memory/guest.wasm
```

`examples/wasm_full_baseline_test.nim` is the common firmware entry source.
It writes status `0x57464D00` on success, the existing capability word, peak
heap bytes, and instance bytes to four 32-bit registers. M0 starts at
`XramBase + 0x3F10`, D0 at `XramBase + 0x3F20`, and LP at `0x40002E90`.
`0x57464D7F` means the test entered but has not completed. The other status
codes are in `src/bl808/wasm_full_baseline.nim`.

The physical Ox64 has not run this baseline. When the current Wi-Fi work
releases it, integrate the helper into the real all-core firmware and add its
status reads and success markers to a scoped `tools/hardware_validation.json`
test. Then follow `AGENTS.md`: rediscover the runtime UART with `--list`, run
`--preflight`, run that test with `--build-only` and `--dry-run`, and finally use
`tools/hw_validate.py` with `--uart-anchor-flash`,
`--uart-anchor-reset-after-flash`, `--no-jtag-reset`, and the current UART path.
The harness must own the hardware lock. Do not equate these QEMU results with
an Ox64 timing or concurrent XIP result.

The JIT memory allocator now has an opt-in bounded caller-owned region with
explicit write/execute transition hooks. A failed transition rolls back the
new code allocation; M0/D0 publication cleans the data-cache range,
invalidates the local instruction cache, and fences the instruction stream.
The host transition test passes and the allocator cross-links on all three
core targets. No BL808 region protection hook, compiled-code execution,
peer instruction-cache handoff, or persistent XIP code cache is enabled yet.
The existing host JIT path and its compiler remain separate from this
bare-metal allocation check.
The default BL808 RISC-V JIT target selectors now use only M/A/F/D/C
extensions reflected in the native build profiles (and E/M/C/Zicsr/Zifencei
for LP); vendor T-Head/V/P profiles have explicit experimental names and are
not selected by default. `nim c -r --skipUserCfg --skipParentCfg
--skipProjCfg --path:src tools/test_wasm_jit_bl808_targets.nim` checks this
selection. This change does not imply that the target JIT backend has run on
the Ox64.

```sh
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on tools/test_wasm_jit_region.nim
for core in m0 d0 lp; do
  nim c -d:bl808$core -d:bl808kernel \
    --nimcache:build/wasm-jit-region/$core-cache \
    --out:build/wasm-jit-region/$core.elf \
    tools/wasm_jit_region_target_check.nim
done
```

The remaining work includes board validation of the M0 and D0 PSRAM frame path,
D0 and LP IPC/SD integration with M0, timing admission under device interference,
physical streamed migration into the M0 SD stage and its LP RAM margins,
migrating WIT resources, full Component Model/WIT coverage, and native execution from a
persistent XIP code cache.

The existing desktop Tier-2 AOT cache now uses format version 5. It keys
records by the module hash and native ISA, pointer ABI, and OS identity;
checks file, function, code, and relocation limits; and validates a CRC-32
over each code/relocation record before linking. Cache installation stages
all functions before publishing any function pointer and rolls back on a
failed region transition. AArch64 relocation sites now emit a fixed
four-instruction MOVZ/MOVK sequence, which the cache loader can patch
without overwriting the following instruction. RISC-V cache linking
rejects records until its relocation encoding is implemented. The
interpreter remains the fallback for a cache miss or rejected record.

This is a host cache integrity gate, not an Ox64 persistent XIP cache or
an authenticity check against a hostile writer. The remaining target work
includes a signed or otherwise trusted installation artifact, target
relocations through a runtime context, inactive flash slots with commit-last
metadata, and verified execution and cache synchronization on each core.
The host gate is:

```sh
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on \
  --nimcache:build/wasm-aotcache-test/nimcache \
  --out:build/wasm-aotcache-test/test tools/test_wasm_aotcache.nim
```

`src/cps/wasm/jit/xip_slot.nim` adds a read-only, bounded inactive-slot
envelope for future target-specific native code. Its 256-byte header page keys a
SHA-256 module digest, native ISA/ABI target, runtime-context ABI and
generation to a SHA-256 digest of at most 256 KiB of relocation-free code.
The commit word begins erased at header offset 96. A trusted installer writes
and reads back the code body starting at offset 256, then programs the entire
header page with the commit word as its final flash program. A header digest
also covers the identity, generation and code metadata so a torn header cannot
silently change slot selection.
The verifier rejects torn commits, wrong targets, wrong module identities,
truncation and changed code, and chooses the newest valid of two slots with
interpreter fallback if neither verifies. This digest detects corruption; it
does not authenticate an untrusted flash writer. The format neither executes
code nor grants executable permission, and no live flash writer is enabled.
The target must still provide relocation-free code through the existing JIT
backend, a verified runtime-context ABI, executable-memory protection and
per-core instruction synchronization before an XIP entry may be called.

The D0 RV64 Tier-2 backend now has a semantic execution gate on QEMU virt:
`python3 tools/run_wasm_d0_jit.py` compiles the common `add` and `f64bits`
exports into a bounded caller-owned region using the conservative ISA target,
calls the generated code, and compares both results with the full interpreter.
The D0 target gate now admits only the pure decoded opcode subset exercised
by those two functions. The same QEMU case rejects `memory.grow`, integer
division, and an out-of-bounds memory load for JIT compilation, then runs
them through the interpreter; division by zero and the load trap there.
This keeps unproven native memory, trap, import, and control-flow paths on the
full interpreter. The compiler's
relocation types are separated from the filesystem AOT cache so the target
pipeline cross-compiles without POSIX I/O. The QEMU case passed on
2026-11-23 with a 246,984-byte heap peak and 12,304 bytes of native stack use.
This exceeds the current D0 firmware's 8 KiB stack, so target compilation
cannot be enabled under that stack reservation. QEMU virt RAM is RWX and its
test hook does not enforce W^X; this gate proves only the two selected
functions' generated semantics. The fallback test proves the interpreter
preserves the two selected traps; it does not prove native code safety,
bounds, imports, budgeting, or Ox64 executable-memory behavior. The speed-optimized
QEMU image has 459,992 bytes of `.text` plus 36,672 bytes of `.bss`; that
profile would leave no useful heap in D0's current 512 KiB DRAM linker. A
separate size-optimized, build-only D0 image that includes the compiler and a
4 KiB code region cross-links with either DRAM text or XIP text. With a 16 KiB
stack reservation, the DRAM image has 223,640 bytes `.text`, 504 `.data`,
12,384 `.bss`, and 270,240 heap; XIP has the same text, data, and BSS but
491,424 heap. The
build-only entry deliberately refuses code publication. It has not run on the
Ox64, and the QEMU heap observation is not an admission proof for either
firmware link. D0 XIP remains unvalidated on the device.

```sh
for mode in dram xip; do
  flags=""
  if [ "$mode" = xip ]; then flags="-d:bl808D0Xip"; fi
  nim c -d:bl808d0 -d:bl808kernel $flags \
    -d:WasmD0NativeStackBytes=16384 \
    --passL:-Wl,--defsym=__bl808_d0_stack_bytes=16384 \
    --nimcache:build/wasm-jit-d0-$mode-firmware/cache \
    --out:build/wasm-jit-d0-$mode-firmware/d0.elf \
    examples/d0_wasm_jit_build_test.nim
done
```

```sh
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on \
  --nimcache:build/wasm-xip-slot/host-cache \
  --out:build/wasm-xip-slot/host-test tools/test_wasm_xip_slot.nim
for core in m0 d0 lp; do
  nim c -d:bl808$core -d:bl808kernel \
    --nimcache:build/wasm-xip-slot/$core-cache \
    --out:build/wasm-xip-slot/$core.elf \
    tools/wasm_xip_slot_target_check.nim
done
```

The host integrity/fallback test and all three target link checks passed on
2026-11-23. Those target checks have no `_start` and only show that the
read-only verifier cross-links on each ISA/ABI; they do not boot or validate
flash mapping on the Ox64.
