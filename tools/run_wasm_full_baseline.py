#!/usr/bin/env python3
"""Build and execute the shared WASM interpreter corpus without touching Ox64."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "wasm-full-baseline"
SOURCE = ROOT / "examples" / "wasm_full_baseline_test.nim"
QEMU_SOURCE = ROOT / "tools" / "wasm_full_qemu.nim"

CORES = {
    "m0": ("riscv32", "rv32imafc_zicsr", "ilp32f", "rv32,m=true,a=true,f=true,c=true,zicsr=true"),
    "d0": ("riscv64", "rv64imafdc_zicsr", "lp64d", "rv64,m=true,a=true,f=true,d=true,c=true,zicsr=true"),
    "lp": ("riscv32", "rv32emc_zicsr", "ilp32e", "rv32e,m=true,c=true,zicsr=true"),
}


def run(args: list[str], timeout: int = 120) -> str:
    result = subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{' '.join(args)} failed ({result.returncode}):\n"
                           + result.stdout[-5000:])
    return result.stdout


def check_guest_bytes() -> None:
    wasm = OUT / "baseline.wasm"
    run(["wat2wasm", "tools/wasm_full_baseline.wat", "-o", str(wasm)])
    text = (ROOT / "src/bl808/wasm_full_baseline.nim").read_text()
    literal = text.split("WasmFullBaselineModule* = [", 1)[1].split("]", 1)[0]
    embedded = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", literal))
    if wasm.read_bytes() != embedded:
        raise AssertionError("embedded guest differs from tools/wasm_full_baseline.wat")
    print(f"guest bytes: {len(embedded)} (WAT matches)")


def check_lp_arena_growth() -> None:
    guest = OUT / "lp-arena-growth.wasm"
    run(["wat2wasm", "tools/wasm_lp_arena_growth.wat", "-o", str(guest)])
    output = run(["nim", "c", "-r", "-d:bl808lp",
                  "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
                  f"--path:{ROOT / 'src'}", "--checks:on", "--assertions:on",
                  f"--nimcache:{OUT / 'lp-arena-cache'}",
                  f"--out:{OUT / 'lp-arena-test'}",
                  "tools/test_wasm_lp_arena_growth.nim", str(guest)])
    assert "LP-sized full interpreter arenas PASS" in output
    print("LP arena growth and sliced execution: calls, labels, locals, values PASS")


def check_full_store_adapter() -> None:
    output = run(["nim", "c", "-r", "--skipUserCfg", "--skipParentCfg",
                  "--skipProjCfg", f"--path:{ROOT / 'src'}", "--checks:on",
                  "--assertions:on", f"--nimcache:{OUT / 'full-manager-cache'}",
                  f"--out:{OUT / 'full-manager-test'}",
                  "tools/test_wasm_full_manager.nim"])
    assert "full WASM store adapter PASS" in output
    print("full WASM store adapter: CRC, XIP view, f64, sliced call PASS")


def check_full_store_memory_quota() -> None:
    guest = OUT / "full-manager-memory.wasm"
    run(["wat2wasm", "tools/wasm_chunked_memory.wat", "-o", str(guest)])
    output = run(["nim", "c", "-r", "-d:wasmChunkedMemory",
                  "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
                  f"--path:{ROOT / 'src'}", "--checks:on", "--assertions:on",
                  f"--nimcache:{OUT / 'full-manager-memory-cache'}",
                  f"--out:{OUT / 'full-manager-memory-test'}",
                  "tools/test_wasm_full_manager_memory.nim", str(guest)])
    assert "full WASM store memory quota PASS" in output
    print("full WASM store memory quota: chunk factory and grow limit PASS")


def check_firmware(core: str) -> None:
    cache = OUT / f"firmware-{core}-cache"
    elf = OUT / f"firmware-{core}.elf"
    run(["nim", "c", f"-d:bl808{core}", "-d:bl808kernel", "-d:bl808WasmFull",
         f"--nimcache:{cache}", f"--out:{elf}", str(SOURCE)])
    objects = {p.name for p in cache.glob("*.o")}
    assert "@pcps@swasm@sruntime.nim.c.o" in objects, core
    assert "@pcps@swasm@sruntime_int.nim.c.o" not in objects, core
    sections = run(["riscv64-unknown-elf-size", "-A", str(elf)])
    sizes = {name: int(size) for name, size in re.findall(
        r"^(\.[a-z]+)\s+(\d+)\s+\d+", sections, re.M)}
    if core == "lp":
        assert sizes[".data"] + sizes[".bss"] + sizes[".heap"] + sizes[".stack"] <= 16384
        assert sizes[".stack"] == 4096
    print(f"{core} firmware: full runtime; text={sizes['.text']} "
          f"data={sizes['.data']} bss={sizes['.bss']} "
          f"heap={sizes['.heap']} stack={sizes['.stack']}")


def check_d0_xip() -> None:
    """Build-only check of the optional D0 flash mapping; no Ox64 access."""
    elf = OUT / "firmware-d0-xip.elf"
    image = OUT / "firmware-d0-xip.bin"
    cache = OUT / "firmware-d0-xip-cache"
    run(["nim", "c", "-d:bl808d0", "-d:bl808kernel", "-d:bl808WasmFull",
         "-d:bl808D0Xip", f"--nimcache:{cache}",
         f"--out:{elf}", str(SOURCE)])
    objects = {p.name for p in cache.glob("*.o")}
    assert "@pcps@swasm@sruntime.nim.c.o" in objects
    assert "@pcps@swasm@sruntime_int.nim.c.o" not in objects
    sections = run(["riscv64-unknown-elf-objdump", "-h", str(elf)])
    init = re.search(r"^\s*0\s+\.init\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)",
                     sections, re.M)
    data = re.search(r"^\s*2\s+\.data\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)",
                     sections, re.M)
    assert init and data, sections
    assert int(init.group(2), 16) == int(init.group(3), 16) == 0xD8100000
    assert int(data.group(2), 16) == 0x3EF80000
    assert 0xD8100000 < int(data.group(3), 16) < 0xD8200000
    run(["riscv64-unknown-elf-objcopy", "-O", "binary", str(elf), str(image)])
    payload = image.read_bytes()
    assert len(payload) < 1024 * 1024
    assert payload[:4] == (0x30047073).to_bytes(4, "little")
    print(f"d0 XIP build: entry=0xD8100000, DRAM data, {len(payload)} image bytes; bench pending")


def check_scheduler_firmware(core: str) -> None:
    """Cross-link the optional full task path without accessing the board."""
    elf = OUT / f"scheduler-firmware-{core}.elf"
    cache = OUT / f"scheduler-firmware-{core}-cache"
    slots = 1 if core == "lp" else 2
    run(["nim", "c", f"-d:bl808{core}", "-d:bl808kernel",
         "-d:bl808WasmFull", "-d:bl808WasmFullScheduler",
         f"-d:WasmSchedulerMaxTasks={slots}", f"--nimcache:{cache}",
         f"--out:{elf}", "examples/wasm_full_scheduler_test.nim"])
    objects = {p.name for p in cache.glob("*.o")}
    assert "@pcps@swasm@sruntime.nim.c.o" in objects
    assert "@pbl808@swasm_full_manager.nim.c.o" in objects
    sections = run(["riscv64-unknown-elf-size", "-A", str(elf)])
    sizes = {name: int(size) for name, size in re.findall(
        r"^(\.[a-z]+)\s+(\d+)\s+\d+", sections, re.M)}
    if core == "lp":
        writable = sum(sizes[name] for name in (".data", ".bss", ".heap", ".stack"))
        assert writable <= 16384 and sizes[".text"] < 512 * 1024
    print(f"{core} full scheduler firmware: text={sizes['.text']} "
          f"data={sizes['.data']} bss={sizes['.bss']} "
          f"heap={sizes['.heap']} stack={sizes['.stack']}")


def qemu_build(core: str, cpu: str, march: str, abi: str,
               benchmark: bool = False, manager: bool = False,
               scheduler: bool = False, pager: bool = False,
               pager_client: bool = False, steal_client: bool = False,
               rt_resident: bool = False, migration: bool = False,
               psram_frames: bool = False, mutable_migration: bool = False,
               paged_migration: bool = False, staged_migration: bool = False,
               stream_migration: bool = False, soft_steal: bool = False) -> Path:
    linker = "tools/wasm_full_qemu.ld" if core == "lp" else "tools/wasm_full_qemu_large.ld"
    suffix = ("-bench" if benchmark else "-manager" if manager else
              "-scheduler" if scheduler else "-mutable-migration" if mutable_migration else
              "-stream-migration" if stream_migration else
              "-staged-migration" if staged_migration else
              "-migration" if migration else
              "-rt-resident" if rt_resident else
              "-psram-frames" if psram_frames else
              "-soft-steal" if soft_steal else
              "-steal-client" if steal_client else
              "-paged-migration" if paged_migration else
              "-pager-client" if pager_client else
              "-pager" if pager else "")
    elf = OUT / f"qemu-{core}{suffix}.elf"
    run(["nim", "c", "-d:release", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
         f"--path:{ROOT / 'src'}", "--os:any", f"--cpu:{cpu}", "--cc:gcc",
         "--gcc.exe:riscv64-unknown-elf-gcc", "--gcc.linkerexe:riscv64-unknown-elf-gcc",
         "--mm:arc", "-d:useMalloc", "-d:nimNoLibc", "-d:noSignalHandler",
         f"-d:bl808{core}", "-d:bl808WasmFull",
         *(["-d:wasmFullThroughputBench"] if benchmark else []),
         *(["-d:wasmFullManagerQemu"] if manager else []),
         *(["-d:wasmRtResidentQemu", "-d:bl808WasmFullScheduler",
            "-d:bl808WasmRtPolicy", "-d:wasmRtKernelTest", "-d:wasmChunkedMemory",
            "-d:WasmMemoryChunkBytesConfig=512",
            "-d:WasmSchedulerMaxTasks=1"] if rt_resident else []),
         *(["-d:WasmLpNativeStackBytes=5632"] if rt_resident and core == "lp" else []),
         *(["-d:wasmPsramFramesQemu", "-d:wasmPsramFramesEmulated", "-d:wasmTieredFrames",
            "-d:bl808WasmFullScheduler", "-d:WasmSchedulerMaxTasks=1", "-d:wasmChunkedMemory",
            "-d:WasmMemoryChunkBytesConfig=512"] if psram_frames else []),
         *(["-d:wasmFullSchedulerQemu", "-d:bl808WasmFullScheduler",
            f"-d:WasmSchedulerMaxTasks={1 if core == 'lp' else 2}"] if scheduler else []),
         *(["-d:wasmMigrationQemu", "-d:bl808WasmFullScheduler",
            "-d:WasmSchedulerMaxTasks=1"] if migration or mutable_migration or staged_migration else []),
         *(["-d:wasmMutableMigrationQemu", "-d:wasmChunkedMemory",
            "-d:WasmMemoryChunkBytesConfig=512"] if mutable_migration else []),
         *(["-d:wasmStagedMigrationQemu", "-d:wasmChunkedMemory",
            "-d:WasmMemoryChunkBytesConfig=512"] if staged_migration else []),
         *(["-d:WasmLpNativeStackBytes=4608"]
           if (mutable_migration or staged_migration or soft_steal) and core == "lp" else []),
         *(["-d:wasmStealClientQemu", "-d:wasmStealHostTest",
            "-d:bl808WasmFullScheduler", "-d:WasmSchedulerMaxTasks=1"]
           if steal_client or soft_steal else []),
         *(["-d:wasmSoftStealing", "-d:bl808WasmRtPolicy", "-d:WasmRtMaxJobs=1"]
           if soft_steal else []),
         *(["-d:bl808WasmFullScheduler",
            "-d:WasmSchedulerMaxTasks=1", "-d:wasmChunkedMemory",
            "-d:WasmMemoryChunkBytesConfig=512"] if pager or pager_client else []),
         *(["-d:wasmLpPagerQemu"] if core == "lp" and (pager or pager_client) else []),
         *(["-d:wasmPageWireHostTest"] if pager_client else []),
         *(["-d:wasmPagedMigrationQemu"] if paged_migration else []),
         *(["-d:wasmStreamMigration"] if stream_migration else []),
         *(["-d:wasmLpPagerClientQemu", "-d:WasmLpNativeStackBytes=6144"]
           if pager_client and core == "lp" else []),
         *(["-d:wasmD0PagerClientQemu", "-d:wasmTieredFrames", "-d:wasmPsramFramesEmulated"]
           if pager_client and core == "d0" else []),
         "--noMain:on", "--threads:off",
         "--checks:off", "--assertions:off", "--stackTrace:off", "--lineTrace:off",
         "--panics:on",
         f"--passC:-march={march} -mabi={abi} -mcmodel=medany -ffunction-sections -fdata-sections -fno-builtin",
         f"--passL:-march={march} -mabi={abi} -mcmodel=medany -nostdlib -nostartfiles -static -Wl,--gc-sections -T {linker} "
         + ("-Wl,--defsym=__qemu_lp_stack_override=6144 " if pager_client and core == "lp" else
            "-Wl,--defsym=__qemu_lp_stack_override=4608 "
            if (mutable_migration or staged_migration or soft_steal) and core == "lp" else
            "-Wl,--defsym=__qemu_lp_stack_override=5632 " if rt_resident and core == "lp" else "") + "-lgcc",
         f"--nimcache:{OUT / f'qemu-{core}{suffix}-cache'}", f"--out:{elf}", str(QEMU_SOURCE)])
    return elf


def check_qemu_memory(core: str, elf: Path, peak: int, stack: int) -> None:
    sections = run(["riscv64-unknown-elf-size", "-A", str(elf)])
    sizes = {name: int(size) for name, size in re.findall(
        r"^(\.[a-z]+)\s+(\d+)\s+\d+", sections, re.M)}
    assert peak < sizes[".heap"], (core, peak, sizes[".heap"])
    assert stack < sizes[".stack"], (core, stack, sizes[".stack"])
    if core == "lp":
        writable = sum(sizes[name] for name in (".data", ".bss", ".heap", ".stack"))
        assert writable <= 16384, (core, writable)


def check_qemu(core: str, cpu: str, march: str, abi: str, model: str) -> None:
    elf = qemu_build(core, cpu, march, abi)
    executable = "qemu-system-riscv64" if core == "d0" else "qemu-system-riscv32"
    output = run([executable, "-machine", "virt", "-cpu", model, "-m", "32M",
                  "-bios", "none", "-nographic", "-no-reboot", "-kernel", str(elf)], 30)
    marker = f"[PASS] {core.upper()} " + ("RV64" if core == "d0" else "RV32E" if core == "lp" else "RV32")
    if marker not in output or "[FAIL]" in output:
        raise AssertionError(f"{core} QEMU guest failed:\n{output}")
    peak = int(re.search(r"heap peak bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    stack = int(re.search(r"native stack used bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    check_qemu_memory(core, elf, peak, stack)
    print(f"{core} QEMU: i32/f64/indirect PASS; heap peak={peak}, stack used={stack}")


def check_bench(core: str, cpu: str, march: str, abi: str, model: str) -> None:
    elf = qemu_build(core, cpu, march, abi, benchmark=True)
    executable = "qemu-system-riscv64" if core == "d0" else "qemu-system-riscv32"
    output = run([executable, "-machine", "virt", "-cpu", model, "-m", "32M",
                  "-bios", "none", "-nographic", "-no-reboot", "-kernel", str(elf)], 30)
    metrics = {}
    for label in ("iterations", "add cycles", "f64 cycles", "indirect cycles",
                  "heap peak bytes", "native stack used bytes"):
        match = re.search(rf"bench {label}=0x\n([0-9a-f]+)", output)
        if not match:
            raise AssertionError(f"missing {label} in {core} benchmark:\n{output}")
        metrics[label] = int(match.group(1), 16)
    assert metrics["iterations"] == 128
    check_qemu_memory(core, elf, metrics["heap peak bytes"],
                      metrics["native stack used bytes"])
    print(f"{core} QEMU cycles per invoke: add={metrics['add cycles'] // 128}, "
          f"f64={metrics['f64 cycles'] // 128}, "
          f"indirect={metrics['indirect cycles'] // 128}; "
          f"heap peak={metrics['heap peak bytes']}, stack={metrics['native stack used bytes']}")


def check_manager_qemu(core: str, cpu: str, march: str, abi: str, model: str) -> None:
    elf = qemu_build(core, cpu, march, abi, manager=True)
    executable = "qemu-system-riscv64" if core == "d0" else "qemu-system-riscv32"
    output = run([executable, "-machine", "virt", "-cpu", model, "-m", "32M",
                  "-bios", "none", "-nographic", "-no-reboot", "-kernel", str(elf)], 30)
    if f"[PASS] {core.upper()} full WASM store adapter" not in output:
        raise AssertionError(f"{core} QEMU manager failed:\n{output}")
    peak = int(re.search(r"manager heap peak bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    stack = int(re.search(r"manager native stack used bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    check_qemu_memory(core, elf, peak, stack)
    print(f"{core} QEMU full store adapter: peak heap={peak}, stack={stack}")


def check_scheduler_qemu(core: str, cpu: str, march: str, abi: str, model: str) -> None:
    elf = qemu_build(core, cpu, march, abi, scheduler=True)
    executable = "qemu-system-riscv64" if core == "d0" else "qemu-system-riscv32"
    output = run([executable, "-machine", "virt", "-cpu", model, "-m", "32M",
                  "-bios", "none", "-nographic", "-no-reboot", "-kernel", str(elf)], 30)
    if f"[PASS] {core.upper()} full WASM scheduler" not in output:
        raise AssertionError(f"{core} QEMU scheduler failed:\n{output}")
    peak = int(re.search(r"scheduler heap peak bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    stack = int(re.search(r"scheduler native stack used bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    check_qemu_memory(core, elf, peak, stack)
    print(f"{core} QEMU full scheduler: peak heap={peak}, stack={stack}")


def check_migration_qemu(core: str, cpu: str, march: str, abi: str,
                         model: str, mutable: bool = False, staged: bool = False) -> None:
    elf = qemu_build(core, cpu, march, abi, migration=True, mutable_migration=mutable,
                     staged_migration=staged)
    executable = "qemu-system-riscv64" if core == "d0" else "qemu-system-riscv32"
    output = run([executable, "-machine", "virt", "-cpu", model, "-m", "32M",
                  "-bios", "none", "-nographic", "-no-reboot", "-kernel", str(elf)], 30)
    if f"[PASS] {core.upper()} full WASM migration" not in output:
        raise AssertionError(f"{core} QEMU migration failed:\n{output}")
    peak = int(re.search(r"migration heap peak bytes=0x\n([0-9a-f]+)",
                         output).group(1), 16)
    stack = int(re.search(r"migration native stack used bytes=0x\n([0-9a-f]+)",
                          output).group(1), 16)
    check_qemu_memory(core, elf, peak, stack)
    state = "mutable state" if mutable else "guest stacks"
    if staged:
        size = int(re.search(r"migration staged bytes=0x\n([0-9a-f]+)", output).group(1), 16)
        assert size > (512 if core == "lp" else 4096)
        state = f"{size} staged bytes"
    print(f"{core} QEMU portable handoff ({state}): peak heap={peak}, stack={stack}")


def check_rt_resident_qemu(core: str, cpu: str, march: str,
                           abi: str, model: str) -> None:
    elf = qemu_build(core, cpu, march, abi, rt_resident=True)
    executable = "qemu-system-riscv64" if core == "d0" else "qemu-system-riscv32"
    output = run([executable, "-machine", "virt", "-cpu", model, "-m", "32M",
                  "-bios", "none", "-nographic", "-no-reboot", "-kernel", str(elf)], 30)
    marker = f"[PASS] {core.upper()} " + (
        "RV64" if core == "d0" else "RV32E" if core == "lp" else "RV32")
    if f"{marker} resident hard slot" not in output or "[FAIL]" in output:
        raise AssertionError(f"{core} QEMU resident hard slot failed:\n{output}")
    measurements = {}
    for name in ("slice ticks", "start jitter ticks", "heap peak bytes", "native stack used bytes"):
        match = re.search(rf"rt {name}=0x\n([0-9a-f]+)", output)
        if not match:
            raise AssertionError(f"missing {name} in {core} QEMU result:\n{output}")
        measurements[name] = int(match.group(1), 16)
    check_qemu_memory(core, elf, measurements["heap peak bytes"],
                      measurements["native stack used bytes"])
    print(f"{core} QEMU resident hard-slot workload: "
          f"slice={measurements['slice ticks']} emulator ticks, "
          f"start jitter={measurements['start jitter ticks']}, "
          f"heap={measurements['heap peak bytes']}, "
          f"stack={measurements['native stack used bytes']}")


def check_pager_qemu(core: str, pager_client: bool = False, paged_migration: bool = False,
                     stream_migration: bool = False) -> None:
    """Exercise 512-byte chunk backing, optionally through the peer client."""
    cpu, march, abi, model = CORES[core]
    elf = qemu_build(core, cpu, march, abi, pager_client=pager_client,
                     pager=not pager_client, paged_migration=paged_migration,
                     stream_migration=stream_migration)
    output = run([f"qemu-system-{cpu}", "-machine", "virt", "-cpu", model,
                  "-m", "32M", "-bios", "none", "-nographic", "-no-reboot",
                  "-kernel", str(elf)], 30)
    if stream_migration:
        mode = "streamed migration"
    else:
        mode = "paged migration" if paged_migration else "page client task" if pager_client else "paged task"
    marker = f"[PASS] {core.upper()} full WASM {mode}"
    if marker not in output:
        raise AssertionError(f"{core} QEMU pager failed:\n{output}")
    peak = int(re.search(r"pager heap peak bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    stack = int(re.search(r"pager native stack used bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    check_qemu_memory(core, elf, peak, stack)
    print(f"{core} QEMU full {mode}: peak heap={peak}, stack={stack}")
    if core == "d0" and not paged_migration:
        ins = int(re.search(r"pager page ins=0x\n([0-9a-f]+)", output).group(1), 16)
        outs = int(re.search(r"pager page outs=0x\n([0-9a-f]+)", output).group(1), 16)
        print(f"d0 QEMU swap round trip: page-ins={ins}, page-outs={outs}")


def check_steal_client_qemu(core: str, soft: bool = False) -> None:
    """Run a native full task through claim, admission and start acknowledgement."""
    cpu, march, abi, model = CORES[core]
    elf = qemu_build(core, cpu, march, abi, steal_client=True, soft_steal=soft)
    output = run([f"qemu-system-{cpu}", "-machine", "virt", "-cpu", model,
                  "-m", "32M", "-bios", "none", "-nographic", "-no-reboot",
                  "-kernel", str(elf)], 30)
    mode = "soft steal client" if soft else "steal client"
    if f"[PASS] {core.upper()} full WASM {mode}" not in output:
        raise AssertionError(f"{core} QEMU {mode} failed:\n{output}")
    peak = int(re.search(r"steal client heap peak bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    stack = int(re.search(r"steal client native stack used bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    check_qemu_memory(core, elf, peak, stack)
    print(f"{core} QEMU full {mode}: peak heap={peak}, stack={stack}")


def check_psram_frames_qemu(core: str, cpu: str, march: str, abi: str, model: str) -> None:
    elf = qemu_build(core, cpu, march, abi, psram_frames=True)
    executable = "qemu-system-riscv64" if core == "d0" else "qemu-system-riscv32"
    output = run([executable, "-machine", "virt", "-cpu", model, "-m", "32M",
                  "-bios", "none", "-nographic", "-no-reboot", "-kernel", str(elf)], 30)
    marker = "[PASS] D0 RV64" if core == "d0" else "[PASS] M0 RV32"
    if f"{marker} SRAM/PSRAM frames" not in output or "[FAIL]" in output:
        raise AssertionError(f"{core} QEMU SRAM/PSRAM frames failed:\n{output}")
    peak = int(re.search(r"PSRAM frame heap peak bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    stack = int(re.search(r"PSRAM frame native stack used bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    check_qemu_memory(core, elf, peak, stack)
    print(f"{core} QEMU SRAM/PSRAM frames: heap peak={peak}, native stack used={stack}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--d0-xip", action="store_true",
                        help="also build and check the optional D0 XIP image")
    parser.add_argument("--bench", action="store_true",
                        help="also measure QEMU cycle counts for 128 invokes per guest function")
    parser.add_argument("--manager-qemu", action="store_true",
                        help="also run the CRC-checked full store adapter in each core's QEMU image")
    parser.add_argument("--scheduler-qemu", action="store_true",
                        help="also run the opt-in full VM task table in each core's QEMU image")
    parser.add_argument("--migration-qemu", action="store_true",
                        help="also run portable full-task freeze/restore on each QEMU CPU")
    parser.add_argument("--mutable-migration-qemu", action="store_true",
                        help="also run full-task handoff with mutable guest state on each QEMU CPU")
    parser.add_argument("--staged-migration-qemu", action="store_true",
                        help="also restore from reserved staging beyond each core's inline limit")
    parser.add_argument("--rt-resident-qemu", action="store_true",
                        help="run the pinned-memory hard-slot workload on all three QEMU CPUs")
    parser.add_argument("--psram-frames-qemu", action="store_true",
                        help="also exercise separated SRAM and emulated PSRAM frames on M0 and D0")
    parser.add_argument("--scheduler-firmware", action="store_true",
                        help="also cross-link the opt-in full VM task firmware for each core")
    parser.add_argument("--lp-pager-qemu", action="store_true",
                        help="also measure a 512-byte-chunk full task on QEMU RV32E")
    parser.add_argument("--lp-pager-client-qemu", action="store_true",
                        help="also measure LP client RPC overhead with an in-process QEMU server")
    parser.add_argument("--d0-pager-client-qemu", action="store_true",
                        help="also exercise D0 tiered frames and remote swap on QEMU RV64")
    parser.add_argument("--paged-migration-qemu", action="store_true",
                        help="capture and restore evicted chunks over the pager on D0 and LP QEMU")
    parser.add_argument("--stream-migration-qemu", action="store_true",
                        help="stream evicted chunks to emulated storage on D0 and LP QEMU")
    parser.add_argument("--lp-steal-client-qemu", action="store_true",
                        help="also execute a full LP worker claim and task on QEMU RV32E")
    parser.add_argument("--steal-client-qemu", action="store_true",
                        help="exercise job submission and execution on all three CPU profiles")
    parser.add_argument("--soft-steal-qemu", action="store_true",
                        help="also exercise clocked soft-job claims on all three CPU profiles")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    check_guest_bytes()
    if args.migration_qemu:
        run(["wat2wasm", "tools/wasm_migration_small.wat", "-o",
             str(OUT / "migration.wasm")])
        literal = (ROOT / "src/bl808/wasm_migration_corpus.nim").read_text().split(
            "WasmMigrationModule* = [", 1)[1].split("]", 1)[0]
        embedded = bytes(int(x, 16) for x in re.findall(
            r"0x([0-9a-fA-F]{2})", literal))
        assert (OUT / "migration.wasm").read_bytes() == embedded
    if args.mutable_migration_qemu:
        guest = OUT / "migration-mutable.wasm"
        run(["wat2wasm", "tools/wasm_migration_mutable.wat", "-o", str(guest)])
        fixture = (ROOT / "tools/wasm_migration_state_fixture.nim").read_text()
        literal = fixture.split("WasmMutableModule* = [", 1)[1].split("]", 1)[0]
        embedded = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", literal))
        assert guest.read_bytes() == embedded
    if args.staged_migration_qemu:
        guest = OUT / "migration-dense.wasm"
        run(["wat2wasm", "tools/wasm_migration_dense.wat", "-o", str(guest)])
        fixture = (ROOT / "tools/wasm_migration_dense_fixture.nim").read_text()
        literal = fixture.split("WasmDenseModule* = [", 1)[1].split("]", 1)[0]
        embedded = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", literal))
        assert guest.read_bytes() == embedded
    if args.rt_resident_qemu:
        rt_dir = ROOT / "build" / "wasm-rt"
        rt_dir.mkdir(parents=True, exist_ok=True)
        run(["wat2wasm", "tools/wasm_rt_resident.wat", "-o",
             str(rt_dir / "resident.wasm")])
        literal = (ROOT / "src/bl808/wasm_rt_resident.nim").read_text().split(
            "WasmRtResidentModule* = [", 1)[1].split("]", 1)[0]
        embedded = bytes(int(x, 16) for x in re.findall(
            r"0x([0-9a-fA-F]{2})", literal))
        assert (rt_dir / "resident.wasm").read_bytes() == embedded
    print(run(["nim", "c", "-r", "-d:release", "--skipUserCfg", "--skipParentCfg",
               "--skipProjCfg", f"--path:{ROOT / 'src'}", "--checks:on", "--assertions:on",
               f"--nimcache:{OUT / 'host-cache'}", f"--out:{OUT / 'host-test'}",
               "tools/test_wasm_full_baseline.nim"]).splitlines()[-1])
    check_lp_arena_growth()
    check_full_store_adapter()
    check_full_store_memory_quota()
    for core, (cpu, march, abi, model) in CORES.items():
        check_firmware(core)
        check_qemu(core, cpu, march, abi, model)
        if args.bench:
            check_bench(core, cpu, march, abi, model)
        if args.manager_qemu:
            check_manager_qemu(core, cpu, march, abi, model)
        if args.scheduler_qemu:
            check_scheduler_qemu(core, cpu, march, abi, model)
        if args.migration_qemu:
            check_migration_qemu(core, cpu, march, abi, model)
        if args.mutable_migration_qemu:
            check_migration_qemu(core, cpu, march, abi, model, mutable=True)
        if args.staged_migration_qemu:
            check_migration_qemu(core, cpu, march, abi, model, staged=True)
        if args.rt_resident_qemu:
            check_rt_resident_qemu(core, cpu, march, abi, model)
        if args.psram_frames_qemu and core != "lp":
            check_psram_frames_qemu(core, cpu, march, abi, model)
        if args.scheduler_firmware:
            check_scheduler_firmware(core)
    if args.d0_xip:
        check_d0_xip()
    if args.lp_pager_qemu:
        check_pager_qemu("lp")
    if args.lp_pager_client_qemu:
        check_pager_qemu("lp", pager_client=True)
    if args.d0_pager_client_qemu or args.paged_migration_qemu or args.stream_migration_qemu:
        guest = OUT / "d0-page-roundtrip.wasm"
        run(["wat2wasm", "tools/wasm_d0_page_roundtrip.wat", "-o", str(guest)])
        fixture = (ROOT / "tools/wasm_d0_page_fixture.nim").read_text()
        literal = fixture.split("WasmD0PageModule* = [", 1)[1].split("]", 1)[0]
        embedded = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", literal))
        assert guest.read_bytes() == embedded
    if args.d0_pager_client_qemu:
        check_pager_qemu("d0", pager_client=True)
    if args.paged_migration_qemu:
        for core in ("d0", "lp"):
            check_pager_qemu(core, pager_client=True, paged_migration=True)
    if args.stream_migration_qemu:
        for core in ("d0", "lp"):
            check_pager_qemu(core, pager_client=True, paged_migration=True, stream_migration=True)
    if args.steal_client_qemu:
        for core in CORES:
            check_steal_client_qemu(core)
    elif args.lp_steal_client_qemu:
        check_steal_client_qemu("lp")
    if args.soft_steal_qemu:
        for core in CORES:
            check_steal_client_qemu(core, soft=True)


if __name__ == "__main__":
    main()
