# Unstarted full-VM job stealing

`wasm_steal_broker.nim` owns a bounded table of eight jobs on M0. Each core
can submit unstarted work and claim compatible work from either of the other
cores. D0 and LP use the existing 504-byte XRAM `ipcbridge` slots. M0 uses
local dispatch to the same broker on its kernel loop. D0 to LP and LP to D0
handoffs go through M0. The firmware needs no additional XRAM region.

A descriptor names an immutable flash slot, an export taking up to four
i32 arguments, a fuel quota, a guest page limit, and its dependencies.
Keep the installed slot stable until queued work has completed. Core
affinity uses bits 1, 2, and 4 for M0, D0, and LP respectively. Select a
single bit for jobs tied to one core. The worker must offer all required
execution backends, host interfaces, and initialized platform resources
and enough guest pages. Zero is a zero-page growth quota. Direct PSRAM is
eligible on M0 and D0 when initialized. Direct SD is eligible on M0.
LP can advertise paged backing through its configured XRAM memory factory.
Pass that factory and its context to `initWasmStealClient` when setting
`WasmStealPagedBacking`. The worker uses the registered factory to prepare
claimed jobs. A paged advertisement without the factory is rejected.
Firmware can assign resource bits 8–15 to additional dependencies, such as
a D0-local device or an IPC service. Use the same bit assignments on all
three cores. Set the bit in the job's `requiredResources` and advertise it
in a worker's `resourceMask` only after the dependency is available. Keep
advertised resources available for the lifetime of the worker's jobs.
Affinity can still be broad, so another core becomes eligible if it can
provide the same dependency.

Best-effort workers derive advertised host bits from local typed
`FullWasmHostBinding` registrations. The application assigns the same
interface bits and meaning across the firmware images, and keeps the
registered service valid for each task's lifetime. Preparation resolves
every core Wasm function import by module name, field name, and exact
signature. Only interfaces declared by the job can be linked. An unavailable
binding declines the job for that worker's current boot, leaving it
eligible elsewhere while the worker can claim other work. RT-policy builds
keep these host bindings disabled pending a bounded host call contract.

A module declaring linear memory also needs a local memory factory on M0
or LP. Preparation checks the module even when the job allows zero pages.
A worker without the factory declines that job for its current boot, so it
can claim other work and a worker with suitable memory can run the job.

The descriptor carries scalar input and no VM instance, local resource
handles, or native stack. The worker prepares a normal full task using the
destination's flash mapping. It leaves the task dormant until the M0 broker
rechecks eligibility and acknowledges the start. The opt-in managed
migration path below can transfer an eligible started job at a portable
suspension point.

The owner serializes claims, applies capability and affinity checks, and
leases only unstarted jobs. An expired or reset peer's unstarted claim returns
to the queue. A started job is never silently retried after peer reset; it
remains a tombstone until the peer reports completion or the M0 owner confirms
the peer stopped and explicitly retires it. Start acknowledgment retries are
idempotent. This preserves
at-most-once admission at the cost of possible stranded work after a lost
acknowledgment. The client never exposes a prepared task before acknowledgment.
The protocol's wire encoding is fixed little-endian and independent of
RV32/RV64 Nim object layout. All three images must use the same protocol.
Use `beginWasmStealSession` followed by `beginWasmStealOffer` to submit
without claiming work. Offers use increasing per-boot tickets and an
explicit M0 epoch. Retrying the latest accepted ticket in that epoch
returns the same job ID. An unresolved submission should be recovered
before issuing a newer ticket.

## Returning outcomes to the submitting core

The worker's finish packet records the signed i32 result or terminal
status, the trap code where applicable, fuel used, and the actual worker
core. The broker binds outcomes to the job ID, M0 epoch, and authenticated
submitter session. The submitter uses `beginWasmStealReadOutcome` to poll
for its result, records the result, then calls `beginWasmStealAckOutcome`.
`wssEmpty` means the job is pending and `wssOk` on a read returns a
terminal outcome. M0 also has a direct fire-and-forget enqueue API.
M0 callers that need an outcome use the client against the local broker.

The terminal outcome reserves its original entry in the eight-slot table
until acknowledged. The worker can retry the same finish in
`wscFinishRetry`, even after the submitter has read and acknowledged it.
A lost result acknowledgment can be retried in the same session.
The broker remembers each worker's latest finish and each submitter's
latest acknowledgment. A new boot of the submitter discards its unstarted
work and unacknowledged outcomes. Already-started work keeps its worker
claim until the worker finishes or the owner confirms it stopped.

The submitter can cancel a queued or claimed job with
`beginWasmStealCancel`. Once started, cancellation returns `wssBusy`.
An expired unstarted soft job reports `wokDeadline`. A worker confirmed
stopped by the operator reports `wokWorkerStopped`. The worker retains
trapped tasks until their result is captured and explicitly reaped. If
its task was already removed by an external stop, the worker reports
`wokTaskLost`.

The default queue handles best-effort jobs. An opt-in clocked worker can
claim soft jobs under its core-local RT policy. Hard reservations stay
on their admitted core. The queue uses the IPC bridge's explicit cache
handoff. Ox64 transfer validation is pending.

Host checks:

```sh
nim c -r -d:bl808WasmFullScheduler \
  --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on tools/test_wasm_steal_broker.nim
nim c -r -d:bl808WasmFullScheduler -d:wasmStealHostTest \
  --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on tools/test_wasm_steal_client.nim
mkdir -p build/wasm-steal-any
wat2wasm tools/wasm_steal_dependencies.wat -o build/wasm-steal-any/dependencies.wasm
wat2wasm tools/wasm_steal_zero_memory.wat -o build/wasm-steal-any/zero-memory.wasm
nim c -r -d:bl808WasmFullScheduler -d:wasmStealHostTest \
  --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on --nimcache:build/wasm-steal-any/client-cache \
  --out:build/wasm-steal-any/client tools/test_wasm_steal_client.nim \
  build/wasm-steal-any/dependencies.wasm build/wasm-steal-any/zero-memory.wasm
```

The host matrix completes all six directions with all-core affinity and
the full interpreter's `call_indirect` corpus and returns the result to
each source. Tests cover
lost finish and outcome acknowledgment replies, retained traps, bounded
outcome capacity, cancel/start ordering, and worker and source resets.
The dependency fixture exercises a D0-local resource, a compatible job
behind the D0-only entry, a typed host call on D0, an incompatible signature,
an undeclared import, a missing local memory factory, and the zero-page quota.
Add `-d:wasmChunkedMemory
-d:WasmMemoryChunkBytesConfig=512` to the fixture command to exercise a
job offered by D0 and executed by LP using its registered memory factory.
Additional checks cover route spoofing,
capability changes before start, lost offer replies, stale sessions, peer
reset, lease expiry, and duplicate start acknowledgments.

Build-only firmware checks, with separate output directories:

```sh
nim c -d:bl808m0 -d:bl808kernel -d:MaxRpcHandlers=1 \
  --nimcache:build/wasm-m0-steal-firmware/cache \
  --out:build/wasm-m0-steal-firmware/m0.elf \
  examples/m0_wasm_steal_server_build_test.nim
nim c -d:bl808d0 -d:bl808kernel -d:bl808WasmFull \
  -d:bl808WasmFullScheduler -d:WasmSchedulerMaxTasks=2 \
  -d:MaxPendingCalls=2 -d:MaxIpcCompletions=2 \
  --nimcache:build/wasm-d0-steal-firmware/cache \
  --out:build/wasm-d0-steal-firmware/d0.elf \
  examples/wasm_steal_client_build_test.nim
nim c -d:bl808lp -d:bl808kernel -d:bl808WasmFull \
  -d:bl808WasmFullScheduler -d:WasmSchedulerMaxTasks=1 \
  -d:WasmLpNativeStackBytes=5632 -d:MaxRpcHandlers=1 \
  -d:MaxPendingCalls=1 -d:MaxIpcCompletions=1 \
  --passL:-Wl,--defsym=__bl808_lp_stack_bytes=5632 \
  --nimcache:build/wasm-lp-steal-firmware/cache \
  --out:build/wasm-lp-steal-firmware/lp.elf \
  examples/wasm_steal_client_build_test.nim
```

The M0 owner-only example offers slot 2 after an explicit trigger and a
CRC-checked slot read. To build M0 as a worker as well, use
`examples/wasm_steal_client_build_test.nim` with the full scheduler flags
above. These probes read the installed guest image.

The QEMU capacity gate exercises submission, claim, start acknowledgment,
full-interpreter `call_indirect`, and outcome read and acknowledgment on
all three ISA profiles.
It uses an in-process broker and transport.

```sh
python3 tools/run_wasm_full_baseline.py --steal-client-qemu --soft-steal-qemu
nim c -d:bl808lp -d:bl808kernel -d:bl808WasmFull \
  -d:bl808WasmFullScheduler -d:WasmSchedulerMaxTasks=1 \
  -d:WasmLpNativeStackBytes=4096 -d:MaxRpcHandlers=1 \
  -d:MaxPendingCalls=1 -d:MaxIpcCompletions=1 \
  -d:MaxSchedulerTimers=4 \
  --passL:-Wl,--defsym=__bl808_lp_stack_bytes=4096 \
  --nimcache:build/wasm-lp-steal-firmware/lean-cache \
  --out:build/wasm-lp-steal-firmware/lean.elf \
  examples/wasm_steal_client_build_test.nim
```

| QEMU CPU profile | Best-effort heap peak | Best-effort stack used | Soft heap peak | Soft stack used |
| --- | ---: | ---: | ---: | ---: |
| M0 | 11,552 | 4,064 | 11,552 | 4,368 |
| D0 | 47,720 | 6,688 | 47,720 | 7,024 |
| LP | 6,064 | 3,852 | 6,064 | 4,304 |

The native LP all-route probe reserves 364 bytes of `.data`, 4,504
bytes of `.bss`, 7,416 bytes of heap, and a 4,096-byte stack. Its
four-timer profile limits this worker to four simultaneous kernel timers.
Physical IPC, flash access, and interrupt paths need separate high-water
measurements before enabling LP stealing by default.

### All-route firmware probe

Build `examples/wasm_steal_client_build_test.nim` on each core with
`-d:wasmCrossCoreStealProbe -d:bl808WasmFull -d:bl808WasmFullScheduler
-d:WasmSchedulerMaxTasks=1 -d:MaxRpcHandlers=1`. The LP build uses the
four-timer, one-pending-call, one-completion profile above. The M0 build
includes the broker and a local worker. Each core advertises a different
test resource. Jobs have all-core affinity and require the resource
advertised by the selected target.

For a coordinated bench run, place the baseline module in slot 2. Put a
fresh nonzero boot ID at status plus `0x20` on each core before it starts.
The probe status addresses are `0x40002D40` on M0, `0x40002D80` on D0,
and `0x40002EA0` on LP. At source status plus `0x24`, set the target bit
(1 for M0, 2 for D0, 4 for LP) before releasing the source. Set the same
word to zero on the other cores. The source reports `0x57534402` and the
job ID at status plus four. The target reports `0x57534400` and 42 at
status plus four after finishing. The source then also reports
`0x57534400` and 42 at status plus four after reading and acknowledging
the target's outcome. Keep the third core polling and verify it stays at
`0x5753447F`. Repeat for each directed pair under the hardware harness.
Physical validation is pending.

## Soft job stealing and clock correlation

Best effort uses wire v9 with 40-byte control requests and 104-byte
offers and replies. `-d:wasmSoftStealing` selects wire v10 for the broker
and all workers. Control requests stay 40 bytes. Offers and replies grow
to 160 bytes. Each peer's claimed core bit is checked against the hardware
IPC route. M0 passes a fresh, nonzero boot epoch to the server.
The worker also binds each sample to the reply's epoch, session and probe
nonce.

`src/bl808/wasm_rt_clock.nim` uses the worker send/receive and owner
receive/send timestamps. Causality supplies the lower and upper anchors,
including when the two IPC delays differ. The mapping scales durations
using nominal tick rates and a configured relative skew envelope.
Round-trip time, sample age, projection distance and mapped uncertainty
have separate limits. Each soft claim starts with a new sample. Missing
or unusable evidence leaves the worker eligible for best-effort claims.
The four timestamp exchange follows the request/reply pattern in
[RFC 5905 §8](https://www.rfc-editor.org/rfc/rfc5905.html#section-8).

The broker prefers the earliest M0 deadline among compatible soft jobs
and records expiry for unstarted jobs. The worker admits a local soft job
using the latest possible release and earliest possible deadline. The
converted window must fit the upper budget estimate and the slice bound
must fit the local budget. The task waits blocked while M0 acknowledges
ownership. Stale admission after acknowledgment retires that ownership
with zero execution. Steal preparation currently accepts modules whose
initialization can complete without an explicit guest start function.

```sh
mkdir -p build/wasm-soft-steal
wat2wasm tools/wasm_steal_start_guard.wat -o build/wasm-soft-steal/start.wasm
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on --nimcache:build/wasm-soft-steal/clock-cache \
  --out:build/wasm-soft-steal/clock tools/test_wasm_rt_clock.nim
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on -d:bl808WasmFullScheduler -d:bl808WasmRtPolicy \
  -d:wasmStealHostTest -d:wasmSoftStealing \
  --nimcache:build/wasm-soft-steal/host-cache --out:build/wasm-soft-steal/host \
  tools/test_wasm_steal_client.nim build/wasm-soft-steal/start.wasm
python3 tools/run_wasm_full_baseline.py --soft-steal-qemu --lp-steal-client-qemu
```

The host tests check asymmetric delays, different tick rates, stale
epochs, overflow, conservative release, deadline order, bad samples,
late acknowledgments, and fallback. All three QEMU profiles run the correlated
claim and complete a full interpreter task with fake IPC and clock
samples. LP's measured QEMU heap peak is 6,064 bytes. The soft LP
firmware reserves 332 bytes of `.data`, 5,024 bytes of `.bss`, 6,416
bytes of heap, and 4,608 bytes of stack within 16 KiB.

To cross-link the probes, add `-d:wasmSoftStealing` to the M0 owner
command above and to both workers. Add `-d:bl808WasmRtPolicy
-d:WasmRtMaxJobs=1 -d:WasmSchedulerMaxTasks=1` to the worker settings.
For LP use the four-timer profile above and set both LP stack flags to
4,608 bytes. The handoff probe reads the M0 boot epoch at `0x40002D64`
before broker initialization. The worker reads its fresh nonzero boot
ID at its status address plus `0x20`. The existing M0 trigger uses slot
2. At the worker status address plus 8, 12, 16, and 20 it reports accepted
clock samples, maximum round-trip ticks, maximum uncertainty and peak heap.
The firmware images cross-link. Physical clock skew, IPC latency and
admission margins still require coordinated Ox64 runs.

## Migrating a started broker job

`-d:wasmManagedMigration` connects the broker's ownership protocol to the
existing portable snapshot transport. It supports best-effort core Wasm
tasks without host imports. Before accepting snapshot bytes, the
destination asks M0 whether it satisfies the active claim's affinity,
resource, interpreter, and guest page requirements. That check reserves
no ownership. The destination rechecks with M0 before preparing the
handoff and restores a dormant task after validating the flash slot,
module digest, export, and fuel. An incompatible receiver leaves the
source eligible to resume. A managed restore uses the same registered
memory factory and context as the destination's worker, when supplied.
Standalone migration uses the receiver's configured factory. The managed
restore also preserves the job's guest page quota.

After prepare, the source stays frozen while M0 authorizes the checked
destination session. If M0 confirms that the prepared session disappeared
and the source still owns the claim, the source resumes. On authorization,
the source retires its task before sending the destination commit.
The receiver acquires a new claim token from M0
before activation. The old worker cannot finish the job with its former
token. The job keeps its original submitter and consumed fuel. A repeated
authorization or activation grant can recover an ambiguous reply. The
receiver keeps the most recent completed managed transfer receipt after
reaping the task so that the source can resolve a lost activation reply.
An ambiguous authorization leaves the source frozen. After authorization,
an unrecoverable destination reset or transport failure can strand the
transfer. Work is never replayed automatically.

Use `bindWasmMigrationSourceWorker` and `bindWasmMigrationServerWorker`
with the existing migration client and server. Drive each bound worker
from the core's kernel loop. The migration client drives the source
worker's authorization RPC during handoff. The server drives the
destination's broker RPC while preparing and committing. Once active,
the destination drives the task and finishes it through the ordinary
steal client. The destination must have a connected, available worker
before transfer. The managed transport uses wire v5 with a 56-byte header
and up to 448 snapshot bytes in each existing XRAM slot. All managed peers
must use the same version.

All six directed routes are available. D0 and LP send to one another
through M0. Initialize the relay with `initM0WasmMigrationRelay` after the
IPC bridge and poll it with `pollM0WasmMigrationRelay` in the ordinary
kernel loop. M0 uses 1,080 bytes of local RAM for two packet records,
each holding a 504-byte request and one reply. The caller polls for the
forwarded reply by repeating the same packet until its transfer timeout.
M0 checks the claimed source
against the incoming IPC slot. The receiver checks that the packet arrived
from M0 and names the opposite core as its source. The destination still
owns snapshot validation and the broker handoff. Transfer of component
state and WIT resources remains open.

The host test uses the actual queue, interpreter, snapshot wire, and
handoff clients with in-process RPC. It covers all six routes, result
delivery to a third core, lost replies from the broker and both legs of
the relay, and a destination that finishes before the sender sees
activation. It also checks full-size packets, independent relay slots,
source and destination route validation, preservation of fuel, and a stale
finish. A job with all-core affinity and a D0-only resource stays on D0
when either LP or M0 is offered the suspended task. The sender produces
zero snapshot fragments for those attempts, and D0 resumes and returns
the original outcome. The tests also exercise source recovery on export
mismatch, an unreachable destination, and destination reset before authorization.
A lost authorization reply leaves the source frozen until a retry confirms
the outcome. D0-to-LP and D0-to-M0 transfers that need a D0-only resource
send no snapshot fragments.

```sh
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on -d:bl808WasmFullScheduler \
  -d:wasmManagedMigration -d:wasmStealHostTest \
  -d:wasmMigrationClientHostTest -d:wasmMigrationWireHostTest \
  --nimcache:build/wasm-managed-migration/host-cache \
  --out:build/wasm-managed-migration/host tools/test_wasm_managed_migration.nim
```

Add `-d:wasmStreamMigration` to exercise the streaming sender with both an
eligible and an ineligible destination.

Add `-d:wasmChunkedMemory -d:WasmMemoryChunkBytesConfig=512` and pass
`build/wasm-steal-any/zero-memory.wasm` to exercise a D0-to-LP migration
that depends on the advertised backing. M0 declines the same job before
any snapshot fragments are sent. LP restores through its worker's
registered factory and the guest grows memory within its one-page quota.

Build the native probe from `examples/wasm_steal_client_build_test.nim`
using the all-route flags above, plus `-d:wasmManagedMigration
-d:wasmManagedMigrationProbe -d:MaxRpcHandlers=2`. Add
`-d:wasmManagedMigrationProbeReceiver` to the destination. On LP, use
`-d:WasmLpNativeStackBytes=4608` and
`--passL:-Wl,--defsym=__bl808_lp_stack_bytes=4608`. The test guest in
slot 2 is `tools/wasm_migration_small.wat` compiled with `wat2wasm`.
Set the migration target bit at the source worker's status plus
`0x28`. Set status plus `0x2C` to one on the destination so it waits for
a handoff. Use the third core as submitter by setting its status plus
`0x24` to the final destination bit. Clear unused control words and set
fresh boot IDs on all three cores. The source worker reports the
handoff, and the destination and submitter each report the value 42.
For D0 to LP and LP to D0, M0 submits the test job and runs the relay.
The build-only hardware harness builds both relayed probe configurations.
Its LP profile uses a 4,096-byte stack and 388 bytes of `.data`.
The sender has 5,336 bytes of `.bss` and 6,560 bytes of heap. The receiver
has 5,992 bytes of `.bss` and 5,904 bytes of heap.
The physical device and actual RAM high-water marks still need coordinated
bench validation.

## Portable guest suspension gate

The full scheduler now freezes a yielded task through
`captureWasmTaskMigration`, using the interpreter's bounded, checksummed
`WasmPortableSnapshot`. The source stops running until it is canceled or
retired. A receiver opens its own CRC-checked slot image, compares the module
SHA-256 embedded in the snapshot, restores the guest stacks and PCs, and
holds the new task dormant until `activateWasmTaskMigration`. Source
retirement must precede activation. If the eventual commit is lost, work may
strand but must never replay on both cores. The scheduler rejects real-time
registered jobs, host imports, and host resources. The snapshot contains
guest state only. After a Wasm tail call replaces the first frame, the
snapshot keeps the original entry export and restores the current callee
frame after checking that its result types match the entry.

The scheduler APIs are transport-neutral. The opt-in
`wasm_migration_wire.nim`, `wasm_migration_client.nim`, and
`wasm_migration_server.nim` now carry snapshots in bounded fragments through
the existing 504-byte IPC bridge payload. A source freezes before transfer;
the receiver stages one snapshot, verifies its own flash slot and module
digest outside the IPC handler, and waits for a commit. The source retires
before sending that commit. Transfer IDs, receiver epochs, source boot IDs,
affinity, idempotent fragment retries, and a lease reject stale or stranded
uncommitted work. If commit delivery is uncertain, the source stays retired;
the client can query and retry it but cannot resume the old task. Inline
storage admits 512 bytes on LP and 4,096 bytes on M0/D0. The current
bridge routes through M0. The firmware receiver checks the source core
against the actual XRAM request slot before handling a message.

The host regression exercises freeze/cancel, wrong module and corrupt
snapshot rejection, source retirement, destination activation and final
result. The QEMU gate repeats a small memoryless task on RV32, RV64 and RV32E
with a 512-byte snapshot cap and one task slot. This is a local restore on
each emulator, not a measured inter-core handoff.

```sh
wat2wasm tools/wasm_lp_arena_growth.wat -o build/wasm-migration/deep.wasm
wat2wasm tools/wasm_migration_other.wat -o build/wasm-migration/other.wasm
nim c -r -d:bl808WasmFullScheduler \
  --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on \
  --nimcache:build/wasm-migration/host-cache \
  --out:build/wasm-migration/host-test \
  tools/test_wasm_scheduler_migration.nim \
  build/wasm-migration/deep.wasm build/wasm-migration/other.wasm
python3 tools/run_wasm_full_baseline.py --migration-qemu
```

The QEMU observations on 2026-11-23 were M0 10,360 bytes heap/3,264 native
stack, D0 45,568/5,600, and LP 4,872/3,100. Separate M0, D0 and LP firmware
images with the migration API called all cross-link. The LP image has 200
bytes `.data`, 2,932 `.bss`, 9,156 heap and 4,096 stack in its 16 KiB
writable region. These are an isolated small-module capacity check, not a
bound for the XRAM IPC receiver or a physical Ox64 run.

The wire and async-client host tests use an in-process receiver and fake IPC
future. They cover lost fragment and commit replies, idempotent retry,
deferred preparation, wrong session, peer reset, lease expiry, prepare failure,
and an uncertain commit. They do not model XRAM cache handoff or an actual
peer reset on the Ox64:

```sh
wat2wasm tools/wasm_migration_small.wat -o build/wasm-migration/small.wasm
nim c -r -d:bl808WasmFullScheduler -d:wasmMigrationWireHostTest \
  --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on \
  --nimcache:build/wasm-migration/wire-cache \
  --out:build/wasm-migration/wire-test \
  tools/test_wasm_migration_wire.nim build/wasm-migration/small.wasm
nim c -r -d:bl808WasmFullScheduler -d:wasmMigrationWireHostTest \
  -d:wasmMigrationClientHostTest \
  --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on \
  --nimcache:build/wasm-migration/client-cache \
  --out:build/wasm-migration/client-test \
  tools/test_wasm_migration_client.nim build/wasm-migration/small.wasm
```

Separate `examples/wasm_migration_client_build_test.nim` and
`examples/wasm_migration_server_build_test.nim` images link on all three
cores with one full task and one IPC handler. The LP client link has 276
bytes `.data`, 4,840 `.bss`, 7,168 heap and 4,096 stack; the LP server link
has 252 `.data`, 4,256 `.bss`, 7,776 heap and 4,096 stack. The host tests
passed and the images linked, but these margins are not a measured live IPC
capacity. The server's poll hook must run outside hard reservations, and
the caller must provide a nonzero boot epoch that changes across resets.
Keep migration opt-in until paired Ox64 runs confirm RAM high water, XRAM
handoff, peer reset behavior, and module identity across flash mappings.

## Mutable core guest state

The v2 snapshot carries a single memory's page count and page limit, sparse
nonzero byte runs, table contents and growth, mutable globals, and dropped
data and element flags. Local function references use addresses derived from
the verified module. Stack-only snapshots continue to use v1. A destination
recreates the private store without executing the guest start function again.
It checks the full image and its memory admission before applying state,
then remains dormant until the existing ownership commit.

Flat memory can be captured or restored transparently. Chunked capture reads
resident frames directly and can fetch evicted chunks through synchronous
or asynchronous backing without changing the source cache. The synchronous
restore API requires the image to fit resident frames. The migration receiver
can also prepare into a private chunk cache backed by swap.
An unfinished memory operation remains ineligible for capture even after its
page fault is serviced. Exception continuations, guest imports, and WIT
resources still need migration support.

The host tests check a flat-to-chunked restore, synchronous backed chunks,
partial-instruction rejection, destination quota rejection, and wire
prepare/commit. The sample grows memory, crosses a 64 KiB boundary, clears an
active data byte, changes a global, grows a table, and drops passive segments.
It passes through the full scheduler on all three QEMU cores. The fixture
returned `16909075`; its flat-memory snapshot was 162 bytes.

| QEMU core | Peak heap | Native stack used |
| --- | ---: | ---: |
| M0 | 14,080 | 4,340 |
| D0 | 50,336 | 6,416 |
| LP | 8,720 | 4,252 |

LP QEMU uses a 4,608-byte stack and a 16 KiB writable region. The native local
probe links with 228 bytes `.data`, 2,932 bytes `.bss`, 8,612 bytes of heap and
a 4,608-byte stack. The separately linked LP XRAM receiver has 6,024 heap
bytes after its IPC and staging allocations. Admitting this workload requires
a receiver-specific high-water measurement and an Ox64 XRAM run.

```sh
mkdir -p build/wasm-migration-state
wat2wasm tools/wasm_lp_arena_growth.wat -o build/wasm-migration-state/deep.wasm
wat2wasm tools/wasm_migration_mutable.wat -o build/wasm-migration-state/mutable.wasm
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on -d:wasmChunkedMemory -d:WasmMemoryChunkBytesConfig=512 \
  --nimcache:build/wasm-migration-state/chunk-cache \
  --out:build/wasm-migration-state/chunk-test tools/test_wasm_portable_snapshot.nim \
  build/wasm-migration-state/deep.wasm build/wasm-migration-state/mutable.wasm
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on -d:bl808WasmFullScheduler -d:wasmMigrationWireHostTest \
  -d:wasmChunkedMemory -d:WasmMemoryChunkBytesConfig=512 \
  --nimcache:build/wasm-migration-state/wire-cache \
  --out:build/wasm-migration-state/wire-test tools/test_wasm_migration_wire.nim \
  build/wasm-migration-state/mutable.wasm mutable
python3 tools/run_wasm_full_baseline.py --migration-qemu --mutable-migration-qemu
```

`-d:wasmMutableMigrationProbe` selects the mutable fixture in the native
local, source, and receiver examples. Build with `-d:wasmChunkedMemory`,
`-d:WasmMemoryChunkBytesConfig=512` and `-d:WasmSchedulerMaxTasks=1`. The LP
probe uses `-d:WasmLpNativeStackBytes=4608` and
`--passL:-Wl,--defsym=__bl808_lp_stack_bytes=4608`. The receiver's local slot 2
must contain the exact guest bytes from `tools/wasm_migration_mutable.wat`.

### Migration through the asynchronous pager

On D0 and LP, capture can wait on the existing M0 page RPCs before sending
the first migration message. It reads into one private chunk buffer and
leaves guest residency, eviction order, and pending faults intact. A failed
or timed-out capture leaves the source runnable. Cancel and task teardown
detach the temporary buffer from an outstanding RPC before releasing it.
The page client retains its own transport response buffer until the RPC
finishes. The receiver validates the whole snapshot, then replays sparse byte
runs through the normal chunk cache. It keeps the destination dormant and
replies `mwsPending` while it waits for swap writes. It sends `mwPrepared`
only after restore finishes. A refused write, abort, or expired lease discards
the uncommitted destination. New writes require a destination-owned slot range
with capacity for all committed chunks in the incoming image because a chunk
retains its slot after paging back in.

The host fixture uses the real page and migration codecs with in-process
peers. It checks delayed page replies, retry, cancellation on timeout and
task teardown, and an exact guest result after resuming the canceled source.
The receiver tests cover insufficient backing, a write failure after partial
replay, and lease expiry during an outstanding write. A direct runtime test
restores a single cross-boundary run from a flat snapshot into a one-frame
destination. D0 and LP QEMU each captured through their pager client, restored
into one resident frame, paged in the restored data, and returned the exact
cross-page value `0x12345678`.

| QEMU core | Peak heap | Native stack used |
| --- | ---: | ---: |
| D0 | 43,904 | 6,368 |
| LP | 3,904 | 3,800 |

```sh
mkdir -p build/wasm-async-migration
wat2wasm tools/wasm_migration_mutable.wat -o build/wasm-async-migration/mutable.wasm
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on -d:bl808WasmFullScheduler -d:wasmChunkedMemory \
  -d:WasmMemoryChunkBytesConfig=512 -d:wasmMigrationWireHostTest \
  -d:wasmMigrationClientHostTest -d:wasmPageWireHostTest -d:wasmAsyncMigrationTest \
  --nimcache:build/wasm-async-migration/host-cache \
  --out:build/wasm-async-migration/host-test tools/test_wasm_migration_client.nim \
  build/wasm-async-migration/mutable.wasm
python3 tools/run_wasm_full_baseline.py --paged-migration-qemu
```

The `-d:wasmPagedMigrationProbe` native images use the SD page owner and
migration receiver together on M0, and one local resident frame per sender
and destination. Build each with `-d:bl808kernel`, `-d:bl808WasmFull`,
`-d:bl808WasmFullScheduler`, `-d:WasmSchedulerMaxTasks=1`,
`-d:wasmChunkedMemory` and `-d:WasmMemoryChunkBytesConfig=512`. Build
`examples/m0_wasm_page_server_build_test.nim` for M0 with
`-d:wasmD0PageServerProbe` and `-d:MaxRpcHandlers=2`. Build
`examples/wasm_migration_client_build_test.nim` for a D0 or LP sender and
`examples/wasm_migration_server_build_test.nim` for a D0 or LP receiver. The LP
links use
`-d:MaxRpcHandlers=1 -d:MaxPendingCalls=1 -d:MaxIpcCompletions=1`,
`-d:WasmLpNativeStackBytes=5632` and
`--passL:-Wl,--defsym=__bl808_lp_stack_bytes=5632`. The LP sender links with
308 bytes `.data`, 6,408 `.bss`, and 4,032 bytes of heap. The LP receiver
links with 308 bytes `.data`, 6,304 `.bss`, and 4,136 bytes of heap. Both
reserve 5,632 stack bytes.

For a later harness run, install the bytes from
`tools/wasm_chunked_memory_suspend.wat` in M0 slot 2. M0 uses the existing SD
setup trigger and reports ready at `0x40002E10`. It provisions
`bl808swap_safe/migrate_wasm.swap` with disjoint LP, D0, and M0 restore slot
ranges. After the sender has booted
and M0 is ready, the sender's arm word is `0x574D43A5` at `0x40003EE0` on D0
or `0x40002ED0` on LP. M0 reports `0x574D5300` at `0x40002E30` when the
activated guest returns the expected value and records nonzero page-in and
page-out counts. These images have cross-linked.
Physical SD and XRAM handoff, reset behavior, and LP heap peak remain to be
measured on the Ox64.

### Transfers using reserved memory

The sender and receiver can each supply an exclusive contiguous staging
region. Capture writes directly into the sender's region. The receiver
assembles the same ordered IPC fragments into its own region and borrows
those bytes during validation and restore, including while a cold restore
waits for the pager. XRAM wire version 2 carries 32-bit snapshot lengths and
fragment offsets in its 44-byte header. The 504-byte IPC budget allows
460 payload bytes per fragment. Build both peers with the same wire version.
Admission is bounded by the caller's actual storage, with a 64 MiB ceiling
on a serialized image. The inline limits remain 512 bytes for LP routes and
4,096 bytes otherwise. The firmware owns region lifetime and must reserve
separate ranges for the two peers and their guest memory.

Store snapshot version 3 supports 32-bit counts of nonzero memory runs.
Long contiguous runs split at the 65,535-byte record limit. Small captures
continue to write v2, and the decoder still accepts stack-only v1 and store
v2. Host tests transfer 65,535 bytes in the legacy format, 70,144 bytes with
a dense run that crosses a guest page boundary, and 458,892 bytes with
65,536 separate runs. The cases check inline limit rejection, CRC failure
before activation, duplicate fragments, lost commit replies, and guard bytes
around both regions. The pager-backed host test also covers a borrowed
receive region during restore and expiry.

| QEMU core | Snapshot bytes | Peak heap | Native stack used |
| --- | ---: | ---: | ---: |
| M0 | 6,346 | 20,352 | 3,392 |
| D0 | 6,346 | 54,752 | 5,856 |
| LP | 910 | 5,104 | 3,220 |

The QEMU test captures and restores locally. M0 and D0 use separate emulated
RAM for this region. LP's 1,024-byte region counts against its 16 KiB
writable budget. Native sender and receiver images cross-link on all three
cores. The LP builds reserve 4,608 stack bytes and leave 4,888 heap bytes on
the sender and 4,992 on the receiver. The local QEMU peak does not establish
admission for the full LP IPC path. Its heap and stack high water still need
to be measured on the Ox64.

```sh
mkdir -p build/wasm-staged-migration
wat2wasm tools/wasm_migration_dense.wat -o build/wasm-staged-migration/dense.wasm
wat2wasm tools/wasm_migration_large.wat -o build/wasm-staged-migration/large.wasm
nim c --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on -d:bl808WasmFullScheduler \
  -d:wasmMigrationWireHostTest -d:wasmMigrationClientHostTest -d:wasmExtendedMigrationTest \
  --nimcache:build/wasm-staged-migration/host-cache \
  --out:build/wasm-staged-migration/host-test tools/test_wasm_migration_client.nim
build/wasm-staged-migration/host-test build/wasm-staged-migration/dense.wasm
build/wasm-staged-migration/host-test build/wasm-staged-migration/large.wasm dense
build/wasm-staged-migration/host-test build/wasm-staged-migration/large.wasm sparse
python3 tools/run_wasm_full_baseline.py --staged-migration-qemu
```

To build either native IPC probe, select `-d:wasmStagedMigrationProbe` on
`examples/wasm_migration_client_build_test.nim` or
`examples/wasm_migration_server_build_test.nim`. Use the full scheduler,
one task slot, `-d:wasmChunkedMemory`, and `-d:WasmMemoryChunkBytesConfig=512`.
M0 and D0 require `-d:WasmMigrationProbePsramOffset` for their respective
8,192-byte regions. Build-only checks used `64946176` on M0 and `64954368`
on D0. For LP use `-d:WasmLpNativeStackBytes=4608`,
`--passL:-Wl,--defsym=__bl808_lp_stack_bytes=4608`, and the same single-entry
IPC limits as the paged probe. `-d:wasmMigrationTargetLP` on the M0 sender
selects the LP-sized workload.

For a later harness run, give the receiver slot 2 the exact bytes generated
from `tools/wasm_migration_dense.wat`. Arm the receiver at status address
plus `0x14` with `0x574D53A5` after explicitly initializing and reserving
PSRAM where used. Arm the sender at its status address plus `0x10` with
`0x574D43A5` after the receiver reports ready. The D0 staged receiver status
address is `0x40003F90`. The existing M0 and LP status addresses apply.

### M0 SD snapshot staging

`-d:wasmStorageMigration` enables a bounded snapshot view backed by a
dedicated preallocated file. M0 uses `src/bl808/wasm_sd_migration.nim` with
the existing FatFs swap-file support. The snapshot file has its own handle
and quota, separate from guest page backing. M0 can use it for capture or
receive. It keeps the handle, callbacks and quota alive through the transfer
and holds the received bytes immutable until the dormant restore completes
or is discarded.

The receiver copies one fragment into its existing receive buffer in the
XRAM handler and replies pending. Its normal scheduler poll writes the
file and advances the acknowledged offset. Lost replies can be retried.
Older duplicate fragments are compared outside the handler. After the last
fragment, the receiver syncs the file and validates the module identity,
CRC and destination memory quotas before creating a dormant task. It
reads payloads in blocks of at most 512 bytes and can replay a file into a
one-frame destination with page backing. The source retires only after
prepare succeeds. A missing file, short write, failed sync, or failed read
before prepare leaves the source eligible to resume. A transfer abandoned
by a peer expires under the existing lease. Boot epochs invalidate the
scratch contents after reset.

This path performs synchronous FatFs I/O from normal scheduler context.
Keep it outside deployments that require an active hard reservation
unless the scheduler can reserve and bound the entire operation.
M0 owns the SD card. D0 and LP can send to a file-backed M0 receiver using
local staging or the streamed path below.

Host tests copied 70,144 and 458,892 bytes between two fixed-length
temporary files. They compared every byte, limited individual reads to
512 bytes, and checked file capacity, queued-fragment expiry, duplicate
replies, CRC rejection, and injected write, sync and read failures. The
pager test validated file-backed capture and restore around asynchronous
page faults and cancellation. The host test uses real files and an
in-process IPC bridge and pager.

```sh
mkdir -p build/wasm-file-migration
wat2wasm tools/wasm_migration_large.wat -o build/wasm-file-migration/large.wasm
wat2wasm tools/wasm_migration_mutable.wat -o build/wasm-file-migration/mutable.wasm
nim c --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on -d:bl808WasmFullScheduler \
  -d:wasmMigrationWireHostTest -d:wasmMigrationClientHostTest \
  -d:wasmStorageMigration -d:wasmFileMigrationTest -d:wasmExtendedMigrationTest \
  --nimcache:build/wasm-file-migration/file-host-cache \
  --out:build/wasm-file-migration/file-host tools/test_wasm_migration_client.nim
build/wasm-file-migration/file-host build/wasm-file-migration/large.wasm dense
build/wasm-file-migration/file-host build/wasm-file-migration/large.wasm sparse
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on -d:bl808WasmFullScheduler \
  -d:wasmMigrationWireHostTest -d:wasmMigrationClientHostTest \
  -d:wasmStorageMigration -d:wasmFileMigrationTest -d:wasmAsyncMigrationTest \
  -d:wasmChunkedMemory -d:WasmMemoryChunkBytesConfig=512 -d:wasmPageWireHostTest \
  --nimcache:build/wasm-file-migration/file-async-cache \
  --out:build/wasm-file-migration/file-async tools/test_wasm_migration_client.nim \
  build/wasm-file-migration/mutable.wasm
```

The M0 firmware entry `examples/m0_wasm_page_server_build_test.nim` with
`-d:wasmSdMigrationProbe -d:wasmStorageMigration -d:wasmD0PageServerProbe`
uses `bl808swap_safe/stage_wasm.swap` with 32 slots (128 KiB payload) and
separate paging file `bl808swap_safe/staged_pages.swap`. Build with the
paged migration settings above and `-d:MaxRpcHandlers=2`. Use the existing
trigger at `0x40002E40` and wait for ready at `0x40002E10`. The D0 staged
sender and the dense fixture specified above drive this probe. M0 reports
`0x574D5300` at `0x40002E30` after restoring the exact dense result and
recording page-outs. For the other direction, build
`examples/wasm_migration_client_build_test.nim` on M0 with
`-d:wasmSdMigrationSourceProbe -d:wasmStorageMigration` and the same VM
settings. It reserves `bl808swap_safe/source_stage.swap` and transfers to
the D0 staged receiver described above.

Both M0 images and their D0 peers cross-link. The M0 receiver reserves
312 bytes of `.data`, 20,028 bytes of `.bss`, 36,492 bytes of heap and an
8,192-byte stack. The M0 source reserves 340 bytes of `.data`, 7,692 bytes
of `.bss`, 48,796 bytes of heap and an 8,192-byte stack. These are link
figures. Physical SD and XRAM behavior, SD transfer time and heap/stack
high-water marks need an Ox64 harness run.

### Streaming paged snapshots to M0

`-d:wasmStreamMigration` enables `beginWasmTaskStreamingMigration`. The sender
freezes a task at the existing portable suspension point and reserves an
upper byte limit at the receiver. It then writes directly into the
existing XRAM request buffer, up to 460 payload bytes per fragment. The
sender retains that fragment until the destination confirms its exact
end offset. Page reads wait until any buffered fragment has been sent and
acknowledged, allowing LP to use a single outstanding XRAM call slot.
Evicted chunks are read through the pager. The cursor holds one page-read
scratch buffer and a bounded index of committed chunks.

Snapshot v4 puts the memory run count and CRC in an eight-byte footer.
The sender emits both as it finishes, so the receiver can append fragments
in order throughout the transfer. The receiver validates the exact byte
count received, CRC, guest identity and destination quotas with the full
interpreter before returning prepare. Packet IDs, leases, source
retirement, and commit retries follow the existing handoff protocol. Both
peers need the stream feature enabled. Existing staged snapshots retain
their v1–v3 formats.

Host tests streamed 70,248-byte and 458,900-byte images to a fixed-size
file. They exercised upper-bound rejection, a producer quota that runs out
after transfer begins, CRC rejection, lost fragment and commit replies,
and exact guest return values. The async test delays a source page read
while the migration shares one logical RPC slot, checks that the source
stays frozen, and exercises kill/cancel with a held reply. The receiver
replays through one resident frame and the same page backing.

The QEMU gate streams the paged test guest to an emulated staging region
with a single 460-byte packet buffer, then restores the recorded value.

| QEMU core | Peak heap bytes | Native stack bytes used |
| --- | ---: | ---: |
| D0 | 43,728 | 6,992 |
| LP | 3,704 | 4,272 |

```sh
mkdir -p build/wasm-stream-migration
wat2wasm tools/wasm_migration_large.wat -o build/wasm-stream-migration/large.wasm
wat2wasm tools/wasm_migration_mutable.wat -o build/wasm-stream-migration/mutable.wasm
stream_flags=(-d:bl808WasmFullScheduler -d:wasmMigrationWireHostTest \
  -d:wasmMigrationClientHostTest -d:wasmStreamMigration -d:wasmStreamingMigrationTest \
  -d:wasmStorageMigration -d:wasmFileMigrationTest)
nim c --skipUserCfg --skipParentCfg --skipProjCfg --path:src --checks:on --assertions:on \
  "${stream_flags[@]}" -d:wasmExtendedMigrationTest \
  --nimcache:build/wasm-stream-migration/host-cache \
  --out:build/wasm-stream-migration/host tools/test_wasm_migration_client.nim
build/wasm-stream-migration/host build/wasm-stream-migration/large.wasm dense
build/wasm-stream-migration/host build/wasm-stream-migration/large.wasm sparse
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src --checks:on --assertions:on \
  "${stream_flags[@]}" -d:wasmAsyncMigrationTest -d:wasmChunkedMemory \
  -d:WasmMemoryChunkBytesConfig=512 -d:wasmPageWireHostTest \
  --nimcache:build/wasm-stream-migration/async-cache \
  --out:build/wasm-stream-migration/async tools/test_wasm_migration_client.nim \
  build/wasm-stream-migration/mutable.wasm
python3 tools/run_wasm_full_baseline.py --stream-migration-qemu
```

For the native D0 or LP sender, build the paged source probe above with
`-d:wasmStreamMigration -d:wasmStreamMigrationProbe` in place of
`-d:wasmPagedMigrationProbe`. Build the M0 SD receiver above with
`-d:wasmStreamMigration` as well. Both senders cross-link. The LP image
reserves 332 bytes of `.data`, 6,432 bytes of `.bss`, 3,984 bytes of heap
and a 5,632-byte stack. The stream probe uses the dense fixture in slot 2
with four 512-byte committed chunks, one local frame and a 4 KiB transfer
quota. The sender reports snapshot length at status plus four and heap
high water at status plus eight. For the QEMU case, the LP peak heap was
280 bytes below the heap available in the native image. The native probe
uses four guest chunks and real IPC, so its RAM margin and the physical
SD and XRAM transfer still need the bench run.
