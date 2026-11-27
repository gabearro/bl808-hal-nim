# Cross-core WebAssembly work and migration

There are two ownership paths in the full-VM scheduler. An unstarted job
can be claimed by a compatible worker. A started task can move only at
an eligible portable suspension point, using the migration protocol.

## Claim an unstarted job

M0 owns the bounded job table and serializes claims. M0 workers call the
broker locally. D0 and LP reach it over the existing XRAM IPC bridge.
The job descriptor names an immutable flash slot, an export taking up to
four i32 values, fuel and guest-page quotas, affinity, and requirements.
Affinity bits are 1 for M0, 2 for D0, and 4 for LP.

Keep the flash slot installed until the job completes. A worker advertises
the execution, backing store, and host interface resources it has
initialized. A paged worker needs a registered memory factory. Best-effort
workers can link explicitly allowed typed host functions. Use consistent
resource and interface bits on all cores.

The worker prepares a dormant task, confirms start with M0, and then
runs it. An expired unstarted claim can return to the queue. A started
job remains owned until completion or explicit retirement after the old
worker is known to have stopped. Completed outcomes go back to the
submitting core.
[Broker](../src/bl808/wasm_steal_broker.nim) ·
[Worker and client](../src/bl808/wasm_steal_client.nim).

## Migrate a suspended task

`wasmManagedMigration` connects the broker to the portable snapshot
transport. The supported contract is a suspended, best-effort core Wasm
task with a portable guest state. The migration gate rejects real-time
registered jobs, host imports, and host resources.

The source freezes the task. The receiver verifies the snapshot, module
identity, export and quotas against its own slot and prepares a dormant
receiver. M0 checks eligibility and ownership for managed jobs. The source
retires before the destination activates. After an ambiguous commit reply,
query or retry the handoff through the protocol. Resuming the retired
source would violate that ownership boundary.

Inline snapshot storage admits 512 bytes for LP routes and 4,096 bytes
for other routes. Larger transfers use exclusive reserved memory or
configured SD staging. `wasmStreamMigration` enables the paged snapshot
streaming path to M0. Match transport versions and profile flags on both
peers. Keep staging regions and guest memory disjoint.
[Scheduler](../src/bl808/wasm_scheduler.nim) ·
[Wire format](../src/bl808/wasm_migration_wire.nim) ·
[Migration client](../src/bl808/wasm_migration_client.nim) ·
[Migration receiver](../src/bl808/wasm_migration_server.nim).

## Run the host and QEMU checks

```sh
python3 tools/run_wasm_full_baseline.py --steal-client-qemu --soft-steal-qemu
python3 tools/run_wasm_full_baseline.py --migration-qemu --mutable-migration-qemu
python3 tools/run_wasm_full_baseline.py --staged-migration-qemu
python3 tools/run_wasm_full_baseline.py --paged-migration-qemu --stream-migration-qemu
```

See the [core baseline](wasm_full_baseline.md) for dependencies. For native
bench work, use [the all-core test manifest](../tools/hardware_validation.json)
and the exact profile under test. Keep QEMU evidence separate from
cross-core timing and peripheral results measured on the Ox64.

The [work-stealing reference snapshot](https://github.com/gabearro/bl808-hal-nim/blob/eb932dddbb56ac5131b3d398e5463f18008fc639/docs/wasm_work_stealing.md)
contains the detailed ownership, staging, and earlier benchmark notes.
